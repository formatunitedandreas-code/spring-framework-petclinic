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
    $updatedText = $updatedLines -join "`r`n"
    Set-Content -Path $path -Value $updatedText -NoNewline

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
    $candidate = @($pocket.candidates | Where-Object { [int]$_.score -ge $MinScore } | Select-Object -First 1)
    if (-not $candidate) {
        Write-Host "ready_no_candidates"
        Write-Host "minScore=$MinScore"
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
    $constantLine = ConvertTo-ConstantLine $constantName $literal

    $classPattern = "(?m)^public class [^{]+\{\r?\n"
    $match = [regex]::Match($replaced, $classPattern)
    if (-not $match.Success) {
        $classPattern = "(?m)^(public\s+)?(abstract\s+)?class [^{]+\{\r?\n"
        $match = [regex]::Match($replaced, $classPattern)
    }
    if (-not $match.Success) {
        throw "Could not find class declaration insertion point in $path."
    }

    $insertAt = $match.Index + $match.Length
    $updated = $replaced.Insert($insertAt, "`r`n$constantLine`r`n")
    Set-Content -Path $path -Value $updated -NoNewline

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "literalOccurrences=$literalCount"
    Write-Host "constantName=$constantName"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/preflight.ps1" -LeasePath $LeasePath
if ($LASTEXITCODE -ne 0) { throw "Threshold preflight failed." }

Assert-CleanWorktree
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
