Set-StrictMode -Version Latest

function Resolve-ThresholdBranchRangeBaseRef {
    param(
        [string] $BaseRef = "",
        [string] $LeasePath = "threshold/leases/current.yaml"
    )

    if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
        if ($BaseRef -like "origin/*") { return $BaseRef }
        return "origin/$BaseRef"
    }

    if (Test-Path $LeasePath) {
        $line = Get-Content $LeasePath | Where-Object { $_ -match "^\s*baseRef:\s*(.+?)\s*$" } | Select-Object -First 1
        if ($line) {
            $leaseBase = ($line -replace "^\s*baseRef:\s*", "").Trim()
            if ($leaseBase -like "origin/*") { return $leaseBase }
            if (-not [string]::IsNullOrWhiteSpace($leaseBase)) { return "origin/$leaseBase" }
        }
    }

    return "origin/main"
}

function Assert-ThresholdBranchRangeDiffClean {
    param(
        [string] $BaseRef = "",
        [string] $LeasePath = "threshold/leases/current.yaml"
    )

    $resolvedBaseRef = Resolve-ThresholdBranchRangeBaseRef -BaseRef $BaseRef -LeasePath $LeasePath
    $head = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
        throw "branch_range_diff_head_missing"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git rev-parse --verify $resolvedBaseRef 2>$null | Out-Null
        $baseRefExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($baseRefExitCode -ne 0) {
        throw "branch_range_diff_base_ref_missing=$resolvedBaseRef"
    }

    Write-Host "branchRangeDiffBaseRef=$resolvedBaseRef"
    Write-Host "branchRangeDiffHead=$head"
    & git diff --check "$resolvedBaseRef...HEAD"
    if ($LASTEXITCODE -ne 0) {
        throw "branch_range_diff_check_failed=$resolvedBaseRef...HEAD"
    }
    Write-Host "branchRangeDiffCheck=passed"
}
