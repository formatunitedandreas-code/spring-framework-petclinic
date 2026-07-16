[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $PocketPath = "threshold/candidate-pocket/current.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
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

function ConvertTo-ContentLineEndings {
    param(
        [string] $Text,
        [string] $Content
    )

    $lineEnding = Get-LineEnding -Content $Content
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return $normalized.Replace("`n", $lineEnding)
}

function Get-LineIndent {
    param([string] $Line)
    $match = [regex]::Match($Line, "^(?<indent>\s*)")
    return $match.Groups["indent"].Value
}

function Test-SimpleStringConstantLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+";\s*$'
}

function Test-SimpleStringConstantWrapCandidateLine {
    param([string] $Line)

    $match = [regex]::Match($Line, '^\s*private static final String [A-Z0-9_]+ = "(?<value>[^"\\]+)";\s*$')
    if (-not $match.Success) {
        return $false
    }

    $value = $match.Groups["value"].Value
    $maxFirstSegmentLength = [Math]::Min(88, $value.Length - 1)
    $splitIndex = $value.LastIndexOf(" ", $maxFirstSegmentLength)
    return $splitIndex -ge 24 -and $splitIndex -lt ($value.Length - 1)
}

function Test-SplitStringConstantLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s+"[^"\\]+";\s*$'
}

function Test-SplitStringConstantStartLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s*$'
}

function Test-SimpleQueryAnnotationLine {
    param([string] $Line)
    return $Line -match '^\s*@Query\(\s*(?:value\s*=\s*)?"(?<value>[^"\\]+)"\s*\)\s*$'
}

function Test-MethodOrAnnotationBoundaryLine {
    param([string] $Line)
    return $Line -match '^\s*(?:@|public\b|private\b|protected\b)'
}

function Find-ConservativeCommentSplitPoint {
    param([string] $Text)

    $minimumPrefix = 24
    $minimumSegmentLength = 16
    $preferredMaxIndex = [Math]::Min(112, $Text.Length - 1)
    if ($preferredMaxIndex -lt $minimumPrefix) {
        return $null
    }

    $spaceSplit = $preferredMaxIndex
    while ($spaceSplit -ge $minimumPrefix) {
        $spaceSplit = $Text.LastIndexOf(" ", $spaceSplit)
        if ($spaceSplit -lt $minimumPrefix) {
            break
        }
        $beforeSplit = $Text.Substring(0, $spaceSplit)
        $lastInlineTagStart = $beforeSplit.LastIndexOf("{@")
        $lastInlineTagEnd = $beforeSplit.LastIndexOf("}")
        if ($lastInlineTagStart -gt $lastInlineTagEnd) {
            $spaceSplit--
            continue
        }
        if ($spaceSplit -lt ($Text.Length - 1) -and
            $spaceSplit -ge $minimumSegmentLength -and
            ($Text.Length - ($spaceSplit + 1)) -ge $minimumSegmentLength) {
            return [pscustomobject]@{
                Index = $spaceSplit
                KeepDelimiter = $false
            }
        }
        $spaceSplit--
    }

    return $null
}
function Write-TextFile {
    param([string] $Path, [string] $Content)
    $encoding = New-Object System.Text.UTF8Encoding $false
    $normalizedContent = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $normalizedContent.EndsWith("`n")) {
        $normalizedContent = "$normalizedContent`n"
    }
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $normalizedContent, $encoding)
}

function Get-FileSha256 {
    param([string] $Path)
    if (-not (Test-Path $Path)) {
        throw "File not found for hashing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
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

function Test-IsRuntimeGovernancePath {
    param([string] $Path)

    $normalizedPath = ConvertTo-RepoPath $Path
    return $normalizedPath -in @(
        "threshold/leases/current.yaml",
        "threshold/lease-state/current-run.json",
        "threshold/candidate-pocket/current.json"
    )
}

function Assert-CleanWorktree {
    param(
        [switch] $AllowRuntimeGovernanceArtifacts
    )

    $status = @(& git status --porcelain)
    if (-not $status) {
        return
    }

    if ($AllowRuntimeGovernanceArtifacts.IsPresent) {
        $unexpectedPaths = New-Object System.Collections.Generic.List[string]
        foreach ($line in $status) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
                continue
            }
            $path = ConvertTo-RepoPath $line.Substring(3).Trim()
            if (-not (Test-IsRuntimeGovernancePath -Path $path)) {
                $unexpectedPaths.Add($path)
            }
        }

        if ($unexpectedPaths.Count -eq 0) {
            return
        }

        throw "Worktree contains non-runtime changes: $($unexpectedPaths -join ', ')"
    }

    throw "Worktree is not clean. run-next-slice requires a clean start."
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

function Invoke-DiscoveryCanary {
    param(
        [string] $LeasePath,
        [string] $GatePath
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-discovery-canary.ps1" `
        -LeasePath $LeasePath `
        -GatePath $GatePath
    if ($LASTEXITCODE -ne 0) {
        throw "Threshold discovery canary failed."
    }
}

function Get-LeaseRunState {
    param([string] $StatePath)
    if (-not (Test-Path $StatePath)) {
        throw "Lease state file not found: $StatePath"
    }
    return Get-Content $StatePath -Raw | ConvertFrom-Json
}

function Set-LeaseTerminalState {
    param(
        [string] $StatePath,
        [string] $TerminalState,
        [string] $Reason
    )

    $state = Get-LeaseRunState -StatePath $StatePath
    $head = (& git rev-parse HEAD).Trim()
    $state.currentHead = $head
    $state.terminalState = $TerminalState
    if (-not $state.PSObject.Properties["terminalReason"]) {
        $state | Add-Member -NotePropertyName "terminalReason" -NotePropertyValue $Reason
    }
    else {
        $state.terminalReason = $Reason
    }
    if (-not $state.PSObject.Properties["discoveryCanaryLastPassedAt"]) {
        $state | Add-Member -NotePropertyName "discoveryCanaryLastPassedAt" -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o")
    }
    else {
        $state.discoveryCanaryLastPassedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $StatePath
}

function Test-AstLiteCandidate {
    param(
        [pscustomobject] $Candidate,
        [string] $Path
    )

    $candidateClass = [string]$Candidate.candidateClass
    if ($candidateClass -notin @("repository_readability_cleanup", "redundant_local_variable_simplification")) {
        return $true
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "threshold/scripts/verify-java-candidate-ast.ps1",
        "-File",
        $Path,
        "-CandidateClass",
        $candidateClass,
        "-Member",
        ([string]$Candidate.member)
    )
    if ($Candidate.PSObject.Properties["constantName"] -and $Candidate.constantName) {
        $args += @("-ConstantName", ([string]$Candidate.constantName))
    }

    $output = @(& powershell.exe @args)
    foreach ($line in $output) {
        Write-Host $line
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "candidateSkippedReason=ast_lite_verification_failed:$($Candidate.candidateId)"
        return $false
    }
    return $true
}

function Resolve-ExecutionPocket {
    param(
        [string] $PocketPath,
        [string] $LeasePath,
        [string] $GatePath
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
    $discoveryOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" -LeasePath $LeasePath -GatePath $GatePath -PocketPath $tempPocketPath
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
    $allCandidates = @(
        $pocket.candidates |
            Where-Object { [int]$_.score -ge $MinScore -and $_.autoPatchable -eq $true }
    )
    if (-not $allCandidates) {
        Write-Host "ready_no_auto_patchable_candidates"
        Write-Host "minScore=$MinScore"
        Write-Host "candidateCount=$(@($pocket.candidates).Count)"
        Write-Host "reviewOnlyCandidateCount=$(@($pocket.candidates | Where-Object { $_.reviewOnly -eq $true }).Count)"
        return $null
    }

    $applicableCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $allCandidates) {
        if (-not $candidate.file) { continue }
        $path = ConvertTo-RepoPath $candidate.file
        if (-not (Test-Path $path)) {
            Write-Host "candidateSkippedReason=missing_file:$($candidate.candidateId)"
            continue
        }

        $content = Get-Content $path -Raw
        $candidateClass = [string]$candidate.candidateClass
        $applicable = $true

        switch ($candidateClass) {
            "duplicate_literal_local_constant_extraction" {
                if (-not $candidate.constantName -or -not $candidate.literal) {
                    Write-Host "candidateSkippedReason=missing_fields:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $literalCount = [regex]::Matches($content, [regex]::Escape([string]$candidate.literal)).Count
                if ($literalCount -lt 2) {
                    Write-Host "candidateSkippedReason=literal_exhausted:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if ($content -match "private\s+static\s+final\s+String\s+$([regex]::Escape([string]$candidate.constantName))\s*=") {
                    Write-Host "candidateSkippedReason=constant_already_exists:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "repository_readability_cleanup" {
                $member = [string]$candidate.member
                if ($member.StartsWith("line-")) {
                    $lineNumber = [int]($member.Substring(5))
                    $lines = Get-Content $path
                    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                        Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                        $applicable = $false
                        break
                    }
                    $line = $lines[$lineNumber - 1]
                    $nextLine = if ($lineNumber -lt $lines.Count) { $lines[$lineNumber] } else { $null }
                    $simpleConstant = Test-SimpleStringConstantWrapCandidateLine $line
                    $splitStartConstant = (Test-SplitStringConstantStartLine $line) -and $nextLine -and ($nextLine -match '^\s*"[^"\\]+";\s*$')
                    if (-not ($simpleConstant -or $splitStartConstant)) {
                        Write-Host "candidateSkippedReason=unsupported_line_cleanup:$($candidate.candidateId)"
                        $applicable = $false
                        break
                    }
                    break
                }

                if (-not $candidate.sqlLiteral -or -not $candidate.constantName) {
                    Write-Host "candidateSkippedReason=missing_fields:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $candidateSqlLiteral = ConvertTo-ContentLineEndings -Text ([string]$candidate.sqlLiteral) -Content $content
                $literalCount = [regex]::Matches($content, [regex]::Escape($candidateSqlLiteral)).Count
                if ($literalCount -lt 1) {
                    Write-Host "candidateSkippedReason=sql_literal_missing:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if ($content -match "private\s+static\s+final\s+String\s+$([regex]::Escape([string]$candidate.constantName))\s*=") {
                    Write-Host "candidateSkippedReason=constant_already_exists:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "spring_data_query_wrap_cleanup" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_line_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if (-not (Test-SimpleQueryAnnotationLine $lines[$lineNumber - 1])) {
                    Write-Host "candidateSkippedReason=unsupported_query_annotation_cleanup:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "string_constant_wrap_cleanup" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_line_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if (-not (Test-SimpleStringConstantWrapCandidateLine $lines[$lineNumber - 1])) {
                    Write-Host "candidateSkippedReason=unsupported_line_cleanup:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "split_string_constant_normalization" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_line_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if (-not (Test-SplitStringConstantLine $lines[$lineNumber - 1])) {
                    Write-Host "candidateSkippedReason=unsupported_line_cleanup:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "utility_readability_cleanup" {
                if (-not $candidate.helperName) {
                    Write-Host "candidateSkippedReason=missing_fields:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if ($content -match "private\s+StopWatch\s+$([regex]::Escape([string]$candidate.helperName))\s*\(" -or
                    $content -match "private\s+[\w<>]+\s+$([regex]::Escape([string]$candidate.helperName))\s*\(") {
                    Write-Host "candidateSkippedReason=helper_already_exists:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "method_spacing_normalization" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_spacing_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -ge $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $spacingAction = if ($candidate.PSObject.Properties["spacingAction"]) { [string]$candidate.spacingAction } else { "insert_blank_line" }
                switch ($spacingAction) {
                    "collapse_extra_blank_line" {
                        if ($lineNumber -lt 3 -or
                            -not [string]::IsNullOrWhiteSpace($lines[$lineNumber - 1]) -or
                            -not [string]::IsNullOrWhiteSpace($lines[$lineNumber - 2]) -or
                            $lines[$lineNumber - 3] -notmatch '^\s*\}\s*$' -or
                            -not (Test-MethodOrAnnotationBoundaryLine $lines[$lineNumber])) {
                            Write-Host "candidateSkippedReason=unsupported_spacing_cleanup:$($candidate.candidateId)"
                            $applicable = $false
                            break
                        }
                    }
                    default {
                        if ($lines[$lineNumber - 1] -notmatch '^\s*\}\s*$' -or
                            -not (Test-MethodOrAnnotationBoundaryLine $lines[$lineNumber])) {
                            Write-Host "candidateSkippedReason=unsupported_spacing_cleanup:$($candidate.candidateId)"
                            $applicable = $false
                            break
                        }
                    }
                }
            }
            "comment_wrap_cleanup" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_comment_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if ($lines[$lineNumber - 1] -notmatch '^\s*\*\s+\S') {
                    Write-Host "candidateSkippedReason=unsupported_comment_cleanup:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
            "line_comment_wrap_cleanup" {
                $member = [string]$candidate.member
                if (-not $member.StartsWith("line-")) {
                    Write-Host "candidateSkippedReason=unsupported_line_comment_marker:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                $lineNumber = [int]($member.Substring(5))
                $lines = Get-Content $path
                if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
                    Write-Host "candidateSkippedReason=line_outside_file:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
                if ($lines[$lineNumber - 1] -notmatch '^\s*//\s+\S') {
                    Write-Host "candidateSkippedReason=unsupported_line_comment_cleanup:$($candidate.candidateId)"
                    $applicable = $false
                    break
                }
            }
        }

        if ($applicable -and -not (Test-AstLiteCandidate -Candidate $candidate -Path $path)) {
            $applicable = $false
        }

        if ($applicable) {
            $applicableCandidates.Add($candidate) | Out-Null
        }
    }

    if (-not $applicableCandidates -or $applicableCandidates.Count -eq 0) {
        Write-Host "ready_no_auto_patchable_candidates"
        Write-Host "minScore=$MinScore"
        Write-Host "candidateCount=$(@($pocket.candidates).Count)"
        Write-Host "reviewOnlyCandidateCount=$(@($pocket.candidates | Where-Object { $_.reviewOnly -eq $true }).Count)"
        Write-Host "applicableCandidateCount=0"
        return $null
    }

    $candidate = @($applicableCandidates | Select-Object -First 1)
    if (-not $candidate) { return $null }
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

function Apply-RedundantLocalVariableSimplification {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }
    if (-not $Candidate.member) { throw "Candidate is missing member field." }

    $variableName = [string]$Candidate.member
    if ($variableName -notmatch "^[a-z][A-Za-z0-9_]*$") {
        throw "Refusing unsafe local variable name '$variableName'."
    }

    $content = Get-Content $path -Raw
    $declarationPattern = "(?ms)(?<indent>^\s*)(?<type>[A-Z][A-Za-z0-9_<>, ?]+)\s+$([regex]::Escape($variableName))\s*=\s*(?<expr>[^;]+);\s*`r?`n\s*return\s+$([regex]::Escape($variableName))\s*;"
    $matches = [regex]::Matches($content, $declarationPattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one immediate return-local candidate for '$variableName', found $($matches.Count)."
    }

    $match = $matches[0]
    $indent = $match.Groups["indent"].Value
    $expression = $match.Groups["expr"].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($expression)) {
        throw "Refusing empty expression for '$variableName'."
    }

    $replacement = "$indent" + "return $expression;"
    $updated = $content.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
    Write-TextFile -Path $path -Content $updated

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "inlinedLocal=$variableName"
}

function Apply-LongStringConstantWrap {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }
    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Long string constant wrap requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*)private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)";\s*$')
    if (-not $match.Success) {
        throw "Line '$lineNumber' is not a supported simple string constant in $path."
    }

    $value = $match.Groups["value"].Value
    $maxFirstSegmentLength = [Math]::Min(88, $value.Length - 1)
    $splitIndex = $value.LastIndexOf(" ", $maxFirstSegmentLength)
    if ($splitIndex -lt 24 -or $splitIndex -ge ($value.Length - 1)) {
        throw "Could not find a conservative split point for string constant '$($match.Groups["name"].Value)'."
    }

    $indent = $match.Groups["indent"].Value
    $name = $match.Groups["name"].Value
    $firstSegment = $value.Substring(0, $splitIndex + 1)
    $secondSegment = $value.Substring($splitIndex + 1)

    $wrapped = @()
    $wrapped += "$indent" + "private static final String $name = `"$firstSegment`" +"
    $wrapped += "$indent    `"$secondSegment`";"

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
    Write-Host "wrappedConstant=$name"
}

function Apply-SpringDataQueryWrapCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Spring Data query wrap cleanup requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*)@Query\(\s*(?:value\s*=\s*)?"(?<value>[^"\\]+)"\s*\)\s*$')
    if (-not $match.Success) {
        throw "Line '$lineNumber' is not a supported Spring Data @Query annotation in $path."
    }

    $value = $match.Groups["value"].Value
    $maxFirstSegmentLength = [Math]::Min(88, $value.Length - 1)
    $splitIndex = $value.LastIndexOf(" ", $maxFirstSegmentLength)
    if ($splitIndex -lt 24 -or $splitIndex -ge ($value.Length - 1)) {
        throw "Could not find a conservative split point for @Query annotation '$lineNumber'."
    }

    $indent = $match.Groups["indent"].Value
    $firstSegment = $value.Substring(0, $splitIndex + 1)
    $secondSegment = $value.Substring($splitIndex + 1)

    $wrapped = @()
    $wrapped += "$indent@Query(`"$firstSegment`" +"
    $wrapped += "$indent    `"$secondSegment`")"

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
    Write-Host "wrappedQueryAnnotationLine=$lineNumber"
}

function Apply-RepositoryReadabilityCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    if ($Candidate.member -and ([string]$Candidate.member).StartsWith("line-")) {
        $lineNumber = [int](([string]$Candidate.member).Substring(5))
        $lines = Get-Content $path
        if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
            throw "Candidate line '$lineNumber' is outside file range in $path."
        }

        $line = $lines[$lineNumber - 1]
        if (Test-SimpleStringConstantLine $line) {
            Apply-LongStringConstantWrap -Candidate $Candidate
            return
        }
        if (Test-SplitStringConstantStartLine $line) {
            Apply-SplitStringConstantNormalization -Candidate $Candidate
            return
        }
        throw "Unsupported repository readability line cleanup in $path."
        return
    }

    if (-not $Candidate.sqlLiteral) { throw "Candidate is missing sqlLiteral field." }
    if (-not $Candidate.constantName) { throw "Candidate is missing constantName field." }

    $content = Get-Content $path -Raw
    $sqlLiteral = ConvertTo-ContentLineEndings -Text ([string]$Candidate.sqlLiteral) -Content $content
    $constantName = [string]$Candidate.constantName
    if ($constantName -notmatch "^[A-Z][A-Z0-9_]*$") {
        throw "Refusing unsafe SQL constant name '$constantName'."
    }

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

function Apply-StringConstantWrapCleanup {
    param([pscustomobject] $Candidate)

    Apply-LongStringConstantWrap -Candidate $Candidate
}

function Apply-SplitStringConstantNormalization {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Split string normalization requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*)private static final String (?<name>[A-Z0-9_]+) = "(?<first>[^"\\]+)" \+\s+"(?<second>[^"\\]+)";\s*$')
    $multilineMatch = $null
    if (-not $match.Success) {
        $match = [regex]::Match($line, '^(?<indent>\s*)private static final String (?<name>[A-Z0-9_]+) = "(?<first>[^"\\]+)" \+\s*$')
        if ($match.Success) {
            if ($lineNumber -ge $lines.Count) {
                throw "Candidate line '$lineNumber' is missing split continuation in $path."
            }
            $nextLine = $lines[$lineNumber]
            $multilineMatch = [regex]::Match($nextLine, '^(?<indent>\s*)"(?<second>[^"\\]+)";\s*$')
            if (-not $multilineMatch.Success) {
                throw "Line '$lineNumber' is not a supported split string constant in $path."
            }
        }
    }
    if (-not $match.Success) {
        throw "Line '$lineNumber' is not a supported split string constant in $path."
    }

    $indent = $match.Groups["indent"].Value
    $name = $match.Groups["name"].Value
    $firstSegment = $match.Groups["first"].Value
    if ($multilineMatch) {
        $secondSegment = $multilineMatch.Groups["second"].Value
        $continuationIndent = $multilineMatch.Groups["indent"].Value
    }
    else {
        $secondSegment = $match.Groups["second"].Value
        $continuationIndent = "$indent    "
    }
    $wrapped = @()
    $wrapped += "$indent" + "private static final String $name = `"$firstSegment`""
    $wrapped += "$continuationIndent+ `"$secondSegment`";"

    $updatedLines = @()
    if ($lineNumber -gt 1) {
        $updatedLines += $lines[0..($lineNumber - 2)]
    }
    $updatedLines += $wrapped
    if ($multilineMatch) {
        if ($lineNumber + 1 -lt $lines.Count) {
            $updatedLines += $lines[($lineNumber + 1)..($lines.Count - 1)]
        }
    }
    elseif ($lineNumber -lt $lines.Count) {
        $updatedLines += $lines[$lineNumber..($lines.Count - 1)]
    }

    $originalText = Get-Content $path -Raw
    $updatedText = $updatedLines -join (Get-LineEnding -Content $originalText)
    Write-TextFile -Path $path -Content $updatedText

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    Write-Host "normalizedConstant=$name"
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

function Apply-MethodSpacingNormalization {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Method spacing normalization requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -ge $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $spacingAction = if ($Candidate.PSObject.Properties["spacingAction"]) { [string]$Candidate.spacingAction } else { "insert_blank_line" }

    $updatedLines = @()
    switch ($spacingAction) {
        "collapse_extra_blank_line" {
            if ($lineNumber -lt 3) {
                throw "Line '$lineNumber' cannot collapse blank-line spacing in $path."
            }
            if (-not [string]::IsNullOrWhiteSpace($lines[$lineNumber - 1]) -or
                -not [string]::IsNullOrWhiteSpace($lines[$lineNumber - 2])) {
                throw "Line '$lineNumber' is not an extra blank line in $path."
            }
            if ($lines[$lineNumber - 3] -notmatch '^\s*\}\s*$') {
                throw "Line before collapsed spacing is not a closing method brace in $path."
            }
            if (-not (Test-MethodOrAnnotationBoundaryLine $lines[$lineNumber])) {
                throw "Line after collapsed spacing is not a method or annotation boundary in $path."
            }

            if ($lineNumber -gt 1) {
                $updatedLines += $lines[0..($lineNumber - 2)]
            }
            if ($lineNumber -lt $lines.Count) {
                $updatedLines += $lines[$lineNumber..($lines.Count - 1)]
            }
        }
        default {
            if ($lines[$lineNumber - 1] -notmatch '^\s*\}\s*$') {
                throw "Line '$lineNumber' is not a closing method brace in $path."
            }
            if (-not (Test-MethodOrAnnotationBoundaryLine $lines[$lineNumber])) {
                throw "Line after '$lineNumber' is not a method or annotation boundary in $path."
            }

            if ($lineNumber -gt 1) {
                $updatedLines += $lines[0..($lineNumber - 1)]
            }
            else {
                $updatedLines += $lines[0]
            }
            $updatedLines += ""
            if ($lineNumber -lt $lines.Count) {
                $updatedLines += $lines[$lineNumber..($lines.Count - 1)]
            }
        }
    }

    $originalText = Get-Content $path -Raw
    $updatedText = $updatedLines -join (Get-LineEnding -Content $originalText)
    Write-TextFile -Path $path -Content $updatedText

    Write-Host "appliedCandidate=$($Candidate.candidateId)"
    Write-Host "changedFile=$path"
    if ($spacingAction -eq "collapse_extra_blank_line") {
        Write-Host "removedBlankLine=$lineNumber"
    }
    else {
        Write-Host "insertedBlankLineAfter=$lineNumber"
    }
}

function Apply-CommentWrapCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Comment wrap cleanup requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*\*\s+)(?<text>\S.*)$')
    if (-not $match.Success) {
        throw "Line '$lineNumber' is not a supported long comment line in $path."
    }

    $indent = $match.Groups["indent"].Value
    $text = $match.Groups["text"].Value.Trim()
    $maxTextLength = [Math]::Max(40, 112 - $indent.Length)
    $splitPoint = Find-ConservativeCommentSplitPoint -Text $text
    if (-not $splitPoint) {
        throw "Could not find a conservative split point for comment line '$lineNumber' using space or URL punctuation."
    }

    $splitIndex = [int]$splitPoint.Index
    $firstSegment = if ([bool]$splitPoint.KeepDelimiter) {
        $text.Substring(0, $splitIndex + 1).TrimEnd()
    }
    else {
        $text.Substring(0, $splitIndex).TrimEnd()
    }
    $secondSegment = $text.Substring($splitIndex + 1).TrimStart()
    $wrapped = @(
        "$indent$firstSegment",
        "$indent$secondSegment"
    )

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
    Write-Host "wrappedCommentLine=$lineNumber"
}

function Apply-LineCommentWrapCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Line comment wrap cleanup requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*//\s+)(?<text>\S.*)$')
    if (-not $match.Success) {
        throw "Line '$lineNumber' is not a supported long line comment in $path."
    }

    $indent = $match.Groups["indent"].Value
    $text = $match.Groups["text"].Value.Trim()
    $splitPoint = Find-ConservativeCommentSplitPoint -Text $text
    if (-not $splitPoint) {
        throw "Could not find a conservative split point for line comment '$lineNumber' using space or URL punctuation."
    }

    $splitIndex = [int]$splitPoint.Index
    $firstSegment = if ([bool]$splitPoint.KeepDelimiter) {
        $text.Substring(0, $splitIndex + 1).TrimEnd()
    }
    else {
        $text.Substring(0, $splitIndex).TrimEnd()
    }
    $secondSegment = $text.Substring($splitIndex + 1).TrimStart()
    $wrapped = @(
        "$indent$firstSegment",
        "$indent$secondSegment"
    )

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
    Write-Host "wrappedLineComment=$lineNumber"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/sync-lease-state.ps1" `
    -LeasePath $LeasePath `
    -StatePath $StatePath `
    -CheckOnly
if ($LASTEXITCODE -ne 0) {
    throw "Threshold lease-state check failed before preflight."
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/preflight.ps1" -LeasePath $LeasePath -AllowDirty
if ($LASTEXITCODE -ne 0) { throw "Threshold preflight failed." }

Assert-CleanWorktree -AllowRuntimeGovernanceArtifacts
Assert-LeaseRuntimeState -LeasePath $LeasePath -StatePath $StatePath
$state = Get-LeaseRunState -StatePath $StatePath
if ([int]$state.remainingBudget.candidates -le 0 -or [int]$state.remainingBudget.commits -le 0) {
    Invoke-DiscoveryCanary -LeasePath $LeasePath -GatePath $GatePath
    Set-LeaseTerminalState -StatePath $StatePath -TerminalState "budget_exhausted_verified" -Reason "remaining candidate or commit budget is exhausted after discovery canary passed"
    Write-Host "budget_exhausted_verified"
    Write-Host "remainingCandidates=$($state.remainingBudget.candidates)"
    Write-Host "remainingCommits=$($state.remainingBudget.commits)"
    exit 0
}

Invoke-DiscoveryCanary -LeasePath $LeasePath -GatePath $GatePath
$executionPocketPath = Resolve-ExecutionPocket -PocketPath $PocketPath -LeasePath $LeasePath -GatePath $GatePath

$candidate = Get-NextCandidate -PocketPath $executionPocketPath -MinScore $MinScore
if (-not $candidate) {
    Set-LeaseTerminalState -StatePath $StatePath -TerminalState "ready_no_candidates_verified" -Reason "no applicable autoPatchable candidates after discovery canary passed"
    exit 0
}

Write-Host "selectedCandidateId=$($candidate.candidateId)"
Write-Host "selectedCandidateClass=$($candidate.candidateClass)"
Write-Host "selectedCandidateScore=$($candidate.score)"
Write-Host "selectedCandidateFile=$($candidate.file)"

$candidatePath = ConvertTo-RepoPath $candidate.file
$beforeHash = Get-FileSha256 -Path $candidatePath

switch ([string]$candidate.candidateClass) {
    "redundant_local_variable_simplification" {
        Apply-RedundantLocalVariableSimplification -Candidate $candidate
    }
    "duplicate_literal_local_constant_extraction" {
        Apply-DuplicateLiteralConstantExtraction -Candidate $candidate
    }
    "private_helper_extraction_for_readability" {
        Apply-ReadableMethodSignatureWrap -Candidate $candidate
    }
    "method_signature_wrap_cleanup" {
        Apply-ReadableMethodSignatureWrap -Candidate $candidate
    }
    "repository_readability_cleanup" {
        Apply-RepositoryReadabilityCleanup -Candidate $candidate
    }
    "spring_data_query_wrap_cleanup" {
        Apply-SpringDataQueryWrapCleanup -Candidate $candidate
    }
    "string_constant_wrap_cleanup" {
        Apply-StringConstantWrapCleanup -Candidate $candidate
    }
    "split_string_constant_normalization" {
        Apply-SplitStringConstantNormalization -Candidate $candidate
    }
    "utility_readability_cleanup" {
        Apply-UtilityReadabilityCleanup -Candidate $candidate
    }
    "method_spacing_normalization" {
        Apply-MethodSpacingNormalization -Candidate $candidate
    }
    "comment_wrap_cleanup" {
        Apply-CommentWrapCleanup -Candidate $candidate
    }
    "line_comment_wrap_cleanup" {
        Apply-LineCommentWrapCleanup -Candidate $candidate
    }
    default {
        throw "Candidate class '$($candidate.candidateClass)' is not yet automatically patchable by run-next-slice."
    }
}

$afterHash = Get-FileSha256 -Path $candidatePath
if ($beforeHash -eq $afterHash) {
    throw "Candidate '$($candidate.candidateId)' produced no materialized file change."
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
