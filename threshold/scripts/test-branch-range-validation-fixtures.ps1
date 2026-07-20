[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/branch-range-validation.ps1")

function Invoke-Git {
    param([string[]] $GitArgs)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& git @GitArgs 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw (($output | ForEach-Object { [string]$_ }) -join "`n")
        }
        return $output
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-ThrowsLike {
    param(
        [string] $Name,
        [string] $Pattern,
        [scriptblock] $ScriptBlock
    )

    try {
        & $ScriptBlock
    }
    catch {
        if ([string]$_.Exception.Message -match $Pattern) {
            Write-Host "expectedStop=$Name"
            return
        }
        throw "Unexpected stop for ${Name}: $($_.Exception.Message)"
    }
    throw "Expected stop did not occur: $Name"
}

$originalLocation = Get-Location
$runtimeRoot = Join-Path $originalLocation "threshold/runtime/branch-range-fixtures"
if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

try {
    Set-Location $runtimeRoot
    Invoke-Git -GitArgs @("init", "--initial-branch=main") | Out-Null
    Invoke-Git -GitArgs @("config", "user.email", "threshold-fixture@example.invalid") | Out-Null
    Invoke-Git -GitArgs @("config", "user.name", "Threshold Fixture") | Out-Null
    "clean" | Set-Content -Path "clean.txt" -Encoding UTF8
    Invoke-Git -GitArgs @("add", "clean.txt") | Out-Null
    Invoke-Git -GitArgs @("commit", "-m", "base") | Out-Null
    Invoke-Git -GitArgs @("remote", "add", "origin", ".") | Out-Null
    Invoke-Git -GitArgs @("update-ref", "refs/remotes/origin/main", "HEAD") | Out-Null
    Invoke-Git -GitArgs @("switch", "-c", "topic-clean") | Out-Null
    "also clean" | Set-Content -Path "feature.txt" -Encoding UTF8
    Invoke-Git -GitArgs @("add", "feature.txt") | Out-Null
    Invoke-Git -GitArgs @("commit", "-m", "clean branch change") | Out-Null
    Assert-ThresholdBranchRangeDiffClean -BaseRef "main"
    Write-Host "branchRangeFixture=clean-range-passed"

    Invoke-Git -GitArgs @("switch", "main") | Out-Null
    Invoke-Git -GitArgs @("switch", "-c", "topic-whitespace") | Out-Null
    "bad trailing whitespace  " | Set-Content -Path "bad.txt" -Encoding UTF8
    Invoke-Git -GitArgs @("add", "bad.txt") | Out-Null
    Invoke-Git -GitArgs @("commit", "-m", "committed whitespace error") | Out-Null
    if ((@(git status --short)).Count -ne 0) { throw "branch_range_fixture_worktree_not_clean" }
    Assert-ThrowsLike -Name "committed-whitespace-error" -Pattern "branch_range_diff_check_failed" -ScriptBlock {
        Assert-ThresholdBranchRangeDiffClean -BaseRef "main"
    }
    Write-Host "branchRangeFixture=clean-worktree-bad-range-detected"

    Assert-ThrowsLike -Name "missing-base-ref" -Pattern "branch_range_diff_base_ref_missing" -ScriptBlock {
        Assert-ThresholdBranchRangeDiffClean -BaseRef "does-not-exist"
    }
}
finally {
    Set-Location $originalLocation
    if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
}

Write-Host "branchRangeValidationFixtures=passed"
