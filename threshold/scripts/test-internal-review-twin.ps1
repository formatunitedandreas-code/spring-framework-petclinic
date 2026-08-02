[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "Expected true: $Name" }
    Write-Host "passed=$Name"
}

function Assert-False {
    param([bool] $Condition, [string] $Name)
    if ($Condition) { throw "Expected false: $Name" }
    Write-Host "passed=$Name"
}

$scriptRoot = Split-Path $PSCommandPath -Parent
$repoRoot = Split-Path (Split-Path $scriptRoot -Parent) -Parent
$originalLocation = Get-Location
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-internal-review-twin-" + [guid]::NewGuid().ToString("N"))

try {
    Set-Location $repoRoot

    $outputPath = Join-Path $tempRoot "internal-review-twin.json"
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot "invoke-internal-review-twin.ps1") -BaseRef "HEAD~1" -OutputPath $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw "Internal Review Twin unexpectedly blocked current head."
    }
    $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-True -Condition ([string]$result.schemaVersion -eq "InternalReviewTwinV0_1") -Name "internal review twin contract is materialized"
    Assert-True -Condition ([bool]$result.coverageComplete) -Name "internal review twin reports complete covered shadow surfaces"
    Assert-True -Condition ([string]$result.recommendedControlOutcome -eq "PROCEED_TO_EXTERNAL_HOLDOUT") -Name "finding-free internal review proceeds only to external holdout"
    Assert-True -Condition ([bool]$result.externalCodexReviewStillRequired) -Name "internal review does not replace external Codex challenger"
    Assert-False -Condition ([bool]$result.authorizing) -Name "internal review twin is not authorizing"
    Assert-False -Condition ([bool]$result.positiveEffectAuthorized) -Name "internal review twin cannot authorize positive effects"
    Assert-True -Condition (@($result.reviewerResults).Count -ge 5) -Name "internal review twin runs multiple typed reviewers"

    $registryPath = Join-Path $repoRoot "threshold/review/registry/internal-reviewers.v0_1.json"
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    Assert-False -Condition ([bool]$registry.authorizing) -Name "internal reviewer registry is not authorizing"
    Assert-True -Condition (@($registry.reviewers | Where-Object { [string]$_.reviewerId -eq "threshold.runtime_literal_reviewer.v0_1" }).Count -eq 1) -Name "runtime literal reviewer is registered"
    Assert-True -Condition (@($registry.reviewers | Where-Object { [string]$_.reviewerId -eq "threshold.candidate_class_reviewer.v0_1" }).Count -eq 1) -Name "candidate class reviewer is registered"

    $libraryText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/lib/candidate-class-provenance.ps1") -Raw
    Assert-True -Condition ($libraryText -match "Remove-ThresholdJavaLineCommentOutsideLiteral") -Name "PR197 URL literal external finding is now locally covered"
    Assert-False -Condition ($libraryText -match '\.IndexOf\("//"\)') -Name "raw double slash detection is blocked by local review predicate"

    $batchText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/run-next-batch.ps1") -Raw
    Assert-True -Condition ($batchText -match "Get-CommentWrapThreshold") -Name "PR197 batch threshold external finding is now locally covered"
    Assert-False -Condition ($batchText -match '\$line\.Length -le 120') -Name "hardcoded batch threshold is blocked by local review predicate"

    Write-Host "internalReviewTwinTests=passed"
}
finally {
    Set-Location $originalLocation
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
