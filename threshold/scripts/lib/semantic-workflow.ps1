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

function Assert-ThresholdSemanticEvidenceFileEconomy {
    [CmdletBinding()]
    param(
        [string] $BaseRef = "origin/main"
    )

    $changed = @(git diff --name-only "$BaseRef...HEAD")
    $forbidden = @($changed | Where-Object {
        $_ -like "threshold/runtime/*" -or
        $_ -like "threshold/candidate-pocket/*" -or
        $_ -like "threshold/lease-state/*" -or
        $_ -like "threshold/leases/current.yaml" -or
        $_ -like "threshold/kgs/*"
    })
    if ($forbidden.Count -gt 0) {
        throw "semantic_file_economy_breach=$($forbidden -join ',')"
    }

    $runEvidence = @($changed | Where-Object { $_ -like "threshold/runs/*" })
    foreach ($path in $runEvidence) {
        if ($path -notmatch "^threshold/runs/[^/]+/(twin-delta|aggregate-receipt|evidence-digests)\.json$") {
            throw "unexpected_semantic_run_evidence=$path"
        }
    }
}
