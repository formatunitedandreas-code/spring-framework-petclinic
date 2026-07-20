[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Resolve-PetClinicRepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $root = (git rev-parse --show-toplevel).Trim()
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($fullPath.Substring($fullRoot.Length).TrimStart("\", "/") -replace "\\", "/")
    }
    return ($Path -replace "\\", "/")
}

function Get-ThresholdSemanticRuntimePaths {
    [CmdletBinding()]
    param(
        [string] $RunId = ""
    )

    $runtimeRoot = "threshold/runtime"
    $runRoot = if ([string]::IsNullOrWhiteSpace($RunId)) { "threshold/runs" } else { "threshold/runs/$RunId" }
    return [pscustomobject]@{
        RuntimeRoot = $runtimeRoot
        LegacyTwinDirectory = "$runtimeRoot/legacy-twin"
        TargetProposalDirectory = "$runtimeRoot/target-proposals"
        CandidatePocketDirectory = "$runtimeRoot/candidate-pocket"
        TestLogDirectory = "$runtimeRoot/test-logs"
        TemporaryWorkorderDirectory = "$runtimeRoot/temporary-workorders"
        RunRoot = $runRoot
        TwinDeltaPath = "$runRoot/twin-delta.json"
        AggregateReceiptPath = "$runRoot/aggregate-receipt.json"
        EvidenceDigestsPath = "$runRoot/evidence-digests.json"
    }
}

function ConvertTo-CanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    return ($Value | ConvertTo-Json -Depth 100 -Compress)
}

function Get-ThresholdSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-ThresholdJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    ConvertTo-Json $Value -Depth 100 | Set-Content -Path $Path -Encoding UTF8
}

function Get-ThresholdFileEconomyPolicy {
    [CmdletBinding()]
    param(
        [string] $PolicyPath = "threshold/policies/file-economy-v0.1.yaml"
    )

    $policy = [ordered]@{
        ForbiddenInPullRequest = @(
            "threshold/runtime/**",
            "threshold/candidate-pocket/**",
            "threshold/lease-state/**",
            "threshold/leases/current.yaml",
            "threshold/kgs/**"
        )
        RequiredFiles = @("twin-delta.json", "aggregate-receipt.json", "evidence-digests.json")
        MaximumEvidenceFiles = 3
        MaximumEvidenceChangedLines = 300
        BranchFinalValidationRequired = $true
    }
    if (-not (Test-Path $PolicyPath)) { return [pscustomobject]$policy }

    $section = ""
    foreach ($line in Get-Content $PolicyPath) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed -match "^forbiddenInPullRequest:") { $section = "forbidden"; continue }
        if ($trimmed -match "^semanticRunEvidence:") { $section = "evidence"; continue }
        if ($trimmed -match "^requiredFiles:") { $section = "required"; $policy.RequiredFiles = @(); continue }
        if ($trimmed -match "^maximumEvidenceFiles:\s*(\d+)") { $policy.MaximumEvidenceFiles = [int]$Matches[1]; continue }
        if ($trimmed -match "^maximumEvidenceChangedLines:\s*(\d+)") { $policy.MaximumEvidenceChangedLines = [int]$Matches[1]; continue }
        if ($trimmed -match "^branchFinalValidationRequired:\s*(true|false)") { $policy.BranchFinalValidationRequired = $Matches[1] -eq "true"; continue }
        if ($trimmed -match "^-\s*(.+)$") {
            if ($section -eq "forbidden") { $policy.ForbiddenInPullRequest += $Matches[1] }
            if ($section -eq "required") { $policy.RequiredFiles += $Matches[1] }
        }
        if ($trimmed -match "^[A-Za-z].+:$" -and $trimmed -notmatch "^requiredFiles:") {
            $section = ""
        }
    }
    return [pscustomobject]$policy
}

function Test-ThresholdPathPattern {
    param(
        [string] $Path,
        [string] $Pattern
    )

    $normalizedPath = $Path -replace "\\", "/"
    $normalizedPattern = $Pattern -replace "\\", "/"
    if ($normalizedPattern.EndsWith("/**")) {
        return $normalizedPath.StartsWith($normalizedPattern.Substring(0, $normalizedPattern.Length - 3), [System.StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $normalizedPattern.Contains("*")) {
        return $normalizedPath -eq $normalizedPattern
    }
    $escaped = [regex]::Escape($normalizedPattern).Replace("\*\*", ".*").Replace("\*", "[^/]*")
    return $normalizedPath -match "^$escaped$"
}

function Get-ThresholdChangedLineCount {
    param(
        [string] $BaseRef,
        [string[]] $RunEvidence
    )

    $changedLines = 0
    $lineStats = @(git diff --numstat "$BaseRef...HEAD" -- threshold/runs)
    foreach ($line in $lineStats) {
        $parts = ([string]$line) -split "\s+"
        foreach ($index in @(0, 1)) {
            if ($parts[$index] -match "^\d+$") {
                $changedLines += [int]$parts[$index]
            }
        }
    }
    $tracked = @(& git ls-files -- threshold/runs)
    foreach ($path in $RunEvidence) {
        if ($tracked -contains $path) { continue }
        if (-not (Test-Path $path)) { continue }
        $changedLines += @(Get-Content $path).Count
    }
    return $changedLines
}

function Assert-ThresholdSemanticEvidenceFileEconomy {
    [CmdletBinding()]
    param(
        [string] $BaseRef = "origin/main",
        [int] $MaximumEvidenceFiles = 0,
        [int] $MaximumEvidenceChangedLines = 0,
        [string] $PolicyPath = "threshold/policies/file-economy-v0.1.yaml",
        [switch] $RequireCompleteRunEvidence
    )

    $policy = Get-ThresholdFileEconomyPolicy -PolicyPath $PolicyPath
    if ($MaximumEvidenceFiles -le 0) { $MaximumEvidenceFiles = [int]$policy.MaximumEvidenceFiles }
    if ($MaximumEvidenceChangedLines -le 0) { $MaximumEvidenceChangedLines = [int]$policy.MaximumEvidenceChangedLines }
    $changed = @(
        @(& git diff --name-only "$BaseRef...HEAD") +
        @(& git ls-files --others --exclude-standard)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    $forbidden = @($changed | Where-Object {
        $path = $_
        @($policy.ForbiddenInPullRequest | Where-Object { Test-ThresholdPathPattern -Path $path -Pattern $_ }).Count -gt 0
    })
    if ($forbidden.Count -gt 0) {
        throw "semantic_file_economy_breach=$($forbidden -join ',')"
    }

    $runEvidence = @($changed | Where-Object { $_ -like "threshold/runs/*" })
    if ($runEvidence.Count -gt $MaximumEvidenceFiles) {
        throw "semantic_file_economy_evidence_file_count_breach=$($runEvidence.Count)"
    }

    if ($runEvidence.Count -gt 0) {
        $changedLines = Get-ThresholdChangedLineCount -BaseRef $BaseRef -RunEvidence $runEvidence
        if ($changedLines -gt $MaximumEvidenceChangedLines) {
            throw "semantic_file_economy_changed_line_breach=$changedLines"
        }
    }

    foreach ($path in $runEvidence) {
        if ($path -notmatch "^threshold/runs/[^/]+/(twin-delta|aggregate-receipt|evidence-digests)\.json$") {
            throw "unexpected_semantic_run_evidence=$path"
        }
    }

    if ($RequireCompleteRunEvidence) {
        $runIds = @($runEvidence | ForEach-Object { ($_ -split "/")[2] } | Sort-Object -Unique)
        foreach ($runId in $runIds) {
            foreach ($fileName in @($policy.RequiredFiles)) {
                $requiredPath = "threshold/runs/$runId/$fileName"
                if ($runEvidence -notcontains $requiredPath) {
                    throw "semantic_file_economy_missing_required_file=$requiredPath"
                }
            }
        }
    }
}
