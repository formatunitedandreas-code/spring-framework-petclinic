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
    $coverageClaims = @($result.reviewerResults | ForEach-Object { @($_.coverageClaims) })
    Assert-True -Condition ($coverageClaims -contains "block_comment_text_block_delimiters_ignored") -Name "internal review twin covers block-comment text-block delimiters"
    Assert-True -Condition ($coverageClaims -contains "reviewer_inputs_bound_to_resolved_head") -Name "internal review twin covers resolved-head reviewer inputs"
    Assert-True -Condition ($coverageClaims -contains "declared_forbidden_paths_mechanically_enforced") -Name "internal review twin covers mechanical forbidden path enforcement"
    Assert-True -Condition ($coverageClaims -contains "java_unicode_escapes_decoded_before_text_block_tracking") -Name "internal review twin covers Unicode text-block delimiter translation"
    Assert-True -Condition ($coverageClaims -contains "java_unicode_line_terminators_split_before_text_block_tracking") -Name "internal review twin covers Unicode-produced line terminator splitting"
    Assert-True -Condition ($coverageClaims -contains "slice_comment_wrap_revalidates_current_javadoc_context") -Name "internal review twin covers single-slice Javadoc revalidation"

    $registryPath = Join-Path $repoRoot "threshold/review/registry/internal-reviewers.v0_1.json"
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    Assert-False -Condition ([bool]$registry.authorizing) -Name "internal reviewer registry is not authorizing"
    Assert-True -Condition (@($registry.reviewers | Where-Object { [string]$_.reviewerId -eq "threshold.runtime_literal_reviewer.v0_1" }).Count -eq 1) -Name "runtime literal reviewer is registered"
    Assert-True -Condition (@($registry.reviewers | Where-Object { [string]$_.reviewerId -eq "threshold.candidate_class_reviewer.v0_1" }).Count -eq 1) -Name "candidate class reviewer is registered"

    $libraryText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/lib/candidate-class-provenance.ps1") -Raw
    Assert-True -Condition ($libraryText -match "Remove-ThresholdJavaLineCommentOutsideLiteral") -Name "PR197 URL literal external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Get-ThresholdJavaTextBlockDelimiterCount") -Name "PR197 escaped text-block delimiter external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Remove-ThresholdJavaCommentsOutsideLiteral") -Name "PR197 block-comment text-block delimiter external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Convert-ThresholdJavaUnicodeEscapes") -Name "PR197 Unicode text-block delimiter external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Split-ThresholdJavaUnicodeTranslatedLine") -Name "PR197 Unicode line-terminator external finding is now locally covered"
    Assert-False -Condition ($libraryText -match '\.IndexOf\("//"\)') -Name "raw double slash detection is blocked by local review predicate"

    $batchText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/run-next-batch.ps1") -Raw
    $sliceText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/run-next-slice.ps1") -Raw
    Assert-True -Condition ($batchText -match "Get-CommentWrapThreshold") -Name "PR197 batch threshold external finding is now locally covered"
    Assert-True -Condition ($batchText -match "Test-BatchJavadocCommentLine") -Name "PR197 prepared batch Javadoc-context external finding is now locally covered"
    Assert-False -Condition ($batchText -match '\$line\.Length -le 120') -Name "hardcoded batch threshold is blocked by local review predicate"
    Assert-True -Condition ($sliceText -match "Test-SliceJavadocCommentLine") -Name "PR197 prepared single-slice Javadoc-context external finding is now locally covered"

    $twinText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/invoke-internal-review-twin.ps1") -Raw
    Assert-True -Condition ($twinText -match "Get-RevisionTextOrEmpty") -Name "internal review twin reads reviewer inputs from resolved head"
    Assert-True -Condition ($twinText -match "Get-RevisionTreeFileSetDigest") -Name "internal review twin binds evidence digests to resolved head"
    Assert-True -Condition ($twinText -match "Test-ReviewPathAgainstPattern") -Name "internal review twin mechanically matches forbidden path patterns"
    Assert-True -Condition ($twinText -match "forbiddenChangedPaths") -Name "internal review twin reports forbidden changed paths"
    Assert-True -Condition ($twinText -match "HOLD_INTERNAL_FINDINGS") -Name "internal review twin holds on P2 findings"
    Assert-True -Condition ($twinText -match "java text block state decodes unicode quote delimiters") -Name "internal review twin requires Unicode delimiter hostile fixture"
    Assert-True -Condition ($twinText -match "java text block state splits unicode-produced line terminators") -Name "internal review twin requires Unicode line-terminator hostile fixture"
    Assert-True -Condition ($twinText -match "run-next-slice revalidates current Javadoc context for prepared candidates") -Name "internal review twin requires single-slice revalidation fixture"

    Write-Host "internalReviewTwinTests=passed"
}
finally {
    Set-Location $originalLocation
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
