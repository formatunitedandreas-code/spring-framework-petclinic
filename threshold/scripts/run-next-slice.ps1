[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $PocketPath = "threshold/candidate-pocket/current.json",
    [int] $MinScore = 70,
    [switch] $SkipMavenTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function ConvertTo-ConstantLine {
    param(
        [string] $ConstantName,
        [string] $Literal
    )
    return "    private static final String $ConstantName = $Literal;"
}

function Get-LineEnding {
    param([string] $Content)
    if ($Content.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Write-TextFile {
    param([string] $Path, [string] $Content)
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $Content, $encoding)
}

function Insert-PrivateStaticStringConstant {
    param(
        [string] $Content,
        [string] $ConstantName,
        [string] $Literal
    )

    if ($Content -match "private\s+static\s+final\s+String\s+$([regex]::Escape($ConstantName))\s*=") {
        throw "Constant '$ConstantName' already exists."
    }

    $constantLine = ConvertTo-ConstantLine $ConstantName $Literal
    $lineEnding = Get-LineEnding -Content $Content
    $staticStringMatches = [regex]::Matches($Content, "(?m)^    private static final String [A-Z0-9_]+ = .+;\r?$")
    if ($staticStringMatches.Count -gt 0) {
        $last = $staticStringMatches[$staticStringMatches.Count - 1]
        return $Content.Insert($last.Index + $last.Length, "$lineEnding$lineEnding$constantLine")
    }

    $classPattern = "(?m)^public class [^{]+\{\r?\n"
    $match = [regex]::Match($Content, $classPattern)
    if (-not $match.Success) {
        $classPattern = "(?m)^(public\s+)?(abstract\s+)?class [^{]+\{\r?\n"
        $match = [regex]::Match($Content, $classPattern)
    }
    if (-not $match.Success) {
        throw "Could not find class declaration insertion point."
    }

    return $Content.Insert($match.Index + $match.Length, "$lineEnding$constantLine$lineEnding")
}

function Apply-ReadableMethodSignatureWrap {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) {
        throw "Candidate file not found: $path"
    }
    if (-not $Candidate.member) {
        throw "Candidate is missing member field."
    }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Unsupported helper candidate marker '$member'."
    }
    $lineNumber = [int]($member.Substring(5))

    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $signatureMatch = [regex]::Match($line, "^(?<indent>\s*)(?<signature>.+?)\(\s*(?<params>.*)\)\s*\{\s*$")
    if (-not $signatureMatch.Success) {
        throw "Candidate line '$lineNumber' is not a method declaration in $path."
    }

    $paramsRaw = $signatureMatch.Groups["params"].Value.Trim()
    $parameters = $paramsRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parameters.Count -lt 2) {
        throw "Candidate line '$lineNumber' has no multi-parameter signature to wrap in $path."
    }

    $indent = $signatureMatch.Groups["indent"].Value
    $signature = $signatureMatch.Groups["signature"].Value.TrimEnd()
    $childIndent = "$indent    "

    $wrapped = @()
    $wrapped += "$indent$signature("
    for ($i = 0; $i -lt $parameters.Count; $i++) {
        $separator = if ($i -lt $parameters.Count - 1) { "," } else { "" }
        $wrapped += "$childIndent$($parameters[$i])$separator"
    }
    $wrapped += "$indent) {"

    $updatedLines = @()
    if ($lineNumber -gt 1) {
        $updatedLines += $lines[0..($lineNumber - 2)]
    }
    $updatedLines += $wrapped
    if ($lineNumber -lt $lines.Count) {
        $updatedLines += $lines[$lineNumber..($lines.Count - 1)]
    }
    $originalText = Get-Content $path -Raw
    $updatedText = $updatedLines -join (Get-LineEnding -Content $originalText)
    Write-TextFile -Path $path -Content $updatedText

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "signatureWrappedLine=$lineNumber"
}

function Assert-CleanWorktree {
    $status = @(& git status --porcelain)
    if ($status) {
        throw "Worktree is not clean. run-next-slice requires a clean start."
    }
}

function Assert-LeaseRuntimeState {
    param(
        [string] $LeasePath,
        [string] $StatePath
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/sync-lease-state.ps1" `
        -LeasePath $LeasePath `
        -StatePath $StatePath `
        -CheckOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Threshold lease-state sync check failed."
    }
}

function Resolve-ExecutionPocket {
    param(
        [string] $PocketPath,
        [string] $LeasePath
    )

    $head = (& git rev-parse HEAD).Trim()
    $executionPocketPath = $PocketPath
    if (Test-Path $PocketPath) {
        $pocket = Get-Content $PocketPath -Raw | ConvertFrom-Json
        if ($pocket.generatedFromHead -eq $head -and $pocket.candidates.Count -gt 0) {
            return $executionPocketPath
        }
    }

    $tempPocketPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-candidate-pocket-$head.json"
    $discoveryOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" -LeasePath $LeasePath -PocketPath $tempPocketPath
    if ($LASTEXITCODE -ne 0) {
        throw "Candidate discovery failed."
    }
    foreach ($line in $discoveryOutput) {
        Write-Host $line
    }
    return $tempPocketPath
}

function Get-NextCandidate {
    param(
        [string] $PocketPath,
        [int] $MinScore
    )

    if (-not (Test-Path $PocketPath)) {
        throw "Candidate pocket not found: $PocketPath"
    }

    $pocket = Get-Content $PocketPath -Raw | ConvertFrom-Json
    $candidate = @(
        $pocket.candidates |
            Where-Object { [int]$_.score -ge $MinScore -and $_.autoPatchable -eq $true } |
            Select-Object -First 1
    )
    if (-not $candidate) {
        Write-Host "ready_no_auto_patchable_candidates"
        Write-Host "minScore=$MinScore"
        Write-Host "candidateCount=$(@($pocket.candidates).Count)"
        Write-Host "reviewOnlyCandidateCount=$(@($pocket.candidates | Where-Object { $_.reviewOnly -eq $true }).Count)"
        return $null
    }
    return $candidate
}

function Apply-DuplicateLiteralConstantExtraction {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }
    if (-not $Candidate.literal) { throw "Candidate is missing literal field." }
    if (-not $Candidate.constantName) { throw "Candidate is missing constantName field." }

    $literal = [string]$Candidate.literal
    $constantName = [string]$Candidate.constantName
    if ($constantName -notmatch "^[A-Z][A-Z0-9_]*$") {
        throw "Refusing unsafe constant name '$constantName'."
    }

    $content = Get-Content $path -Raw
    if ($content -match "private\s+static\s+final\s+String\s+$([regex]::Escape($constantName))\s*=") {
        throw "Constant '$constantName' already exists in $path."
    }

    $literalCount = [regex]::Matches($content, [regex]::Escape($literal)).Count
    if ($literalCount -lt 2) {
        throw "Literal $literal occurs only $literalCount time(s); refusing extraction."
    }

    $replaced = [regex]::Replace($content, [regex]::Escape($literal), $constantName)
    $updated = Insert-PrivateStaticStringConstant -Content $replaced -ConstantName $constantName -Literal $literal
    Write-TextFile -Path $path -Content $updated

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "literalOccurrences=$literalCount"
    Write-Host "constantName=$constantName"
}

function Apply-RepositoryReadabilityCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }
    if (-not $Candidate.sqlLiteral) { throw "Candidate is missing sqlLiteral field." }
    if (-not $Candidate.constantName) { throw "Candidate is missing constantName field." }

    $sqlLiteral = [string]$Candidate.sqlLiteral
    $constantName = [string]$Candidate.constantName
    if ($constantName -notmatch "^[A-Z][A-Z0-9_]*$") {
        throw "Refusing unsafe SQL constant name '$constantName'."
    }

    $content = Get-Content $path -Raw
    $literalRegex = [regex]::new([regex]::Escape($sqlLiteral))
    $literalCount = $literalRegex.Matches($content).Count
    if ($literalCount -lt 1) {
        throw "SQL literal $sqlLiteral was not found in $path."
    }

    $replaced = $literalRegex.Replace($content, $constantName, 1)
    $updated = Insert-PrivateStaticStringConstant -Content $replaced -ConstantName $constantName -Literal $sqlLiteral
    Write-TextFile -Path $path -Content $updated

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "sqlLiteralOccurrences=$literalCount"
    Write-Host "constantName=$constantName"
}

function Apply-UtilityReadabilityCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }
    if ([string]$Candidate.utilityPattern -ne "stopwatch_start_helper") {
        throw "Unsupported utility cleanup pattern '$($Candidate.utilityPattern)'."
    }

    $helperName = [string]$Candidate.helperName
    if ($helperName -notmatch "^[a-z][A-Za-z0-9_]*$") {
        throw "Refusing unsafe utility helper name '$helperName'."
    }

    $content = Get-Content $path -Raw
    if ($content -match "private\s+StopWatch\s+$([regex]::Escape($helperName))\s*\(") {
        throw "Utility helper '$helperName' already exists in $path."
    }

    $blockPattern = "(?s)        StopWatch sw = new StopWatch\(joinPoint\.toShortString\(\)\);\r?\n\r?\n        sw\.start\(""invoke""\);"
    $blockReplacement = "        StopWatch sw = $helperName(joinPoint);"
    $updated = [regex]::Replace($content, $blockPattern, $blockReplacement, 1)
    if ($updated -eq $content) {
        throw "Could not find StopWatch start block in $path."
    }

    $lineEnding = Get-LineEnding -Content $updated
    $helperBlock = @(
        "    private StopWatch $helperName(ProceedingJoinPoint joinPoint) {",
        "        StopWatch sw = new StopWatch(joinPoint.toShortString());",
        "        sw.start(""invoke"");",
        "        return sw;",
        "    }",
        ""
    ) -join $lineEnding

    $insertPattern = "(?m)^    private synchronized void recordInvocation\("
    $insertMatch = [regex]::Match($updated, $insertPattern)
    if (-not $insertMatch.Success) {
        throw "Could not find utility helper insertion point in $path."
    }

    $updated = $updated.Insert($insertMatch.Index, $helperBlock)
    Write-TextFile -Path $path -Content $updated

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "helperName=$helperName"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/preflight.ps1" -LeasePath $LeasePath
if ($LASTEXITCODE -ne 0) { throw "Threshold preflight failed." }

Assert-CleanWorktree
Assert-LeaseRuntimeState -LeasePath $LeasePath -StatePath $StatePath
$executionPocketPath = Resolve-ExecutionPocket -PocketPath $PocketPath -LeasePath $LeasePath

$candidate = Get-NextCandidate -PocketPath $executionPocketPath -MinScore $MinScore
if (-not $candidate) { exit 0 }

Write-Host "selectedCandidateId=$($candidate.candidateId)"
Write-Host "selectedCandidateClass=$($candidate.candidateClass)"
Write-Host "selectedCandidateScore=$($candidate.score)"
Write-Host "selectedCandidateFile=$($candidate.file)"

switch ([string]$candidate.candidateClass) {
    "duplicate_literal_local_constant_extraction" {
        Apply-DuplicateLiteralConstantExtraction -Candidate $candidate
    }
    "private_helper_extraction_for_readability" {
        Apply-ReadableMethodSignatureWrap -Candidate $candidate
    }
    "repository_readability_cleanup" {
        Apply-RepositoryReadabilityCleanup -Candidate $candidate
    }
    "utility_readability_cleanup" {
        Apply-UtilityReadabilityCleanup -Candidate $candidate
    }
    default {
        throw "Candidate class '$($candidate.candidateClass)' is not yet automatically patchable by run-next-slice."
    }
}

$commitSummary = $candidate.expectedDiffSummary
if ([string]::IsNullOrWhiteSpace($commitSummary)) {
    $commitSummary = $candidate.candidateClass
}

$shortSummary = $commitSummary
if ($shortSummary.Length -gt 54) {
    $shortSummary = $shortSummary.Substring(0, 54).Trim()
}

$commitMessage = "Refactor PetClinic $shortSummary"
$completeArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "threshold/scripts/complete-slice.ps1",
    "-LeasePath",
    $LeasePath,
    "-StatePath",
    $StatePath,
    "-CandidateId",
    $candidate.candidateId,
    "-CandidateClass",
    $candidate.candidateClass,
    "-CommitMessage",
    $commitMessage,
    "-AllowedPath",
    $candidate.file
)
if ($SkipMavenTest.IsPresent) { $completeArgs += "-SkipMavenTest" }

& powershell.exe @completeArgs
if ($LASTEXITCODE -ne 0) { throw "complete-slice failed." }

Write-Host "run-next-slice completed"
