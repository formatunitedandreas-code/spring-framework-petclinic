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
    Assert-True -Condition ($coverageClaims -contains "java_unicode_escape_translation_respects_backslash_eligibility") -Name "internal review twin covers Java Unicode escape eligibility"
    Assert-True -Condition ($coverageClaims -contains "ordinary_block_comment_nested_javadoc_opener_not_promoted") -Name "internal review twin covers nested ordinary block-comment Javadoc opener rejection"
    Assert-True -Condition ($coverageClaims -contains "javadoc_target_line_scanned_through_terminator") -Name "internal review twin covers Javadoc target-line terminator scanning"
    Assert-True -Condition ($coverageClaims -contains "text_block_closing_suffix_comment_state_preserved") -Name "internal review twin covers text-block closing suffix comment state"
    Assert-True -Condition ($coverageClaims -contains "javadoc_preformatted_content_not_comment_wrap_candidate") -Name "internal review twin covers preformatted Javadoc exclusion"
    Assert-True -Condition ($coverageClaims -contains "javadoc_same_line_preformatted_content_not_comment_wrap_candidate") -Name "internal review twin covers same-line preformatted Javadoc exclusion"
    Assert-True -Condition ($coverageClaims -contains "javadoc_line_end_pre_tag_starts_preformatted_content") -Name "internal review twin covers line-end pre tag Javadoc exclusion"
    Assert-True -Condition ($coverageClaims -contains "javadoc_pre_tag_source_order_preserved") -Name "internal review twin covers source-order pre tag transitions"
    Assert-True -Condition ($coverageClaims -contains "javadoc_inline_tag_pre_markers_ignored") -Name "internal review twin covers inline Javadoc pre markers"
    Assert-True -Condition ($coverageClaims -contains "javadoc_multiline_inline_tag_depth_preserved") -Name "internal review twin covers multiline inline-tag Javadoc pre markers"
    Assert-True -Condition ($coverageClaims -contains "javadoc_html_comment_pre_markers_ignored") -Name "internal review twin covers HTML-comment Javadoc pre markers"
    Assert-True -Condition ($coverageClaims -contains "javadoc_html_comment_rescan_uses_incoming_state") -Name "internal review twin covers incoming HTML-comment-state preservation"
    Assert-True -Condition ($coverageClaims -contains "review_patch_bound_to_merge_base") -Name "internal review twin covers merge-base patch binding"
    Assert-True -Condition ($coverageClaims -contains "review_forbidden_path_checks_include_rename_sources") -Name "internal review twin covers rename-source forbidden path checks"
    Assert-True -Condition ($coverageClaims -contains "review_changed_paths_use_nul_name_status") -Name "internal review twin covers NUL-delimited name-status parsing"
    Assert-True -Condition ($coverageClaims -contains "slice_comment_wrap_revalidates_current_javadoc_context") -Name "internal review twin covers single-slice Javadoc revalidation"
    Assert-True -Condition ($coverageClaims -contains "slice_comment_wrap_uses_discovery_threshold") -Name "internal review twin covers single-slice threshold revalidation"
    Assert-True -Condition ($coverageClaims -contains "batch_comment_wrap_rejects_same_file_line_markers") -Name "internal review twin covers same-file batch line marker rejection"
    Assert-True -Condition ($coverageClaims -contains "batch_comment_wrap_uses_discovery_split_predicate") -Name "internal review twin covers batch shared split predicate"
    Assert-True -Condition ($coverageClaims -contains "batch_comment_wrap_preserves_final_newline") -Name "internal review twin covers batch trailing newline preservation"
    Assert-True -Condition ($coverageClaims -contains "slice_comment_wrap_revalidates_split_predicate") -Name "internal review twin covers single-slice split revalidation"

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
    Assert-True -Condition ($libraryText -match "Test-ThresholdJavaUnicodeEscapeBackslashIsEligible") -Name "PR197 Unicode eligibility external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "insidePreformattedJavadoc") -Name "PR197 preformatted Javadoc external finding is now locally covered"
    Assert-True -Condition ($libraryText -match '\$targetLineInsidePreformattedJavadoc = \$insidePreformattedJavadoc -or \$lineStartsPreformattedJavadoc') -Name "PR197 same-line preformatted Javadoc external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Update-ThresholdJavadocPreformattedStateInSourceOrder") -Name "PR197 source-order pre tag external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Get-ThresholdJavadocPreformattedTransitions") -Name "PR197 inline Javadoc pre marker external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "InlineTagDepth") -Name "PR197 multiline inline-tag external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "InsideJavadocHtmlComment") -Name "PR197 Javadoc HTML comment external finding is now locally covered"
    Assert-True -Condition ($libraryText -match "Find-ThresholdConservativeCommentSplitPoint") -Name "PR197 shared comment split predicate is now locally covered"
    Assert-False -Condition ($libraryText -match '\.IndexOf\("//"\)') -Name "raw double slash detection is blocked by local review predicate"

    $batchText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/run-next-batch.ps1") -Raw
    $sliceText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/run-next-slice.ps1") -Raw
    Assert-True -Condition ($batchText -match "Get-CommentWrapThreshold") -Name "PR197 batch threshold external finding is now locally covered"
    Assert-True -Condition ($batchText -match "Test-BatchJavadocCommentLine") -Name "PR197 prepared batch Javadoc-context external finding is now locally covered"
    Assert-True -Condition ($batchText -match "same_file_line_marker_rebinding_required") -Name "PR197 same-file batch line-marker external finding is now locally covered"
    Assert-True -Condition ($batchText -match "Test-ThresholdCommentWrapCandidateLine") -Name "PR197 batch split-predicate external finding is now locally covered"
    Assert-True -Condition ($batchText -match "EnsureTrailingNewline") -Name "PR197 trailing newline preservation external finding is now locally covered"
    Assert-False -Condition ($batchText.Contains('foreach ($delimiter in @("/")')) -Name "batch URL punctuation split drift is blocked by local review predicate"
    Assert-False -Condition ($batchText -match '\$line\.Length -le 120') -Name "hardcoded batch threshold is blocked by local review predicate"
    Assert-True -Condition ($sliceText -match "Test-SliceJavadocCommentLine") -Name "PR197 prepared single-slice Javadoc-context external finding is now locally covered"
    Assert-True -Condition ($sliceText -match "comment_wrap_threshold_not_met") -Name "PR197 single-slice threshold external finding is now locally covered"
    Assert-True -Condition ($sliceText -match "Test-ThresholdCommentWrapCandidateLine") -Name "PR197 single-slice split revalidation external finding is now locally covered"
    Assert-True -Condition ($sliceText -match "EnsureTrailingNewline") -Name "PR197 single-slice formatting preservation external finding is now locally covered"
    Assert-True -Condition ($sliceText -match '\$lineEnding = Get-LineEnding -Content \$originalText') -Name "PR197 single-slice line ending preservation external finding is now locally covered"

    $twinText = Get-Content -LiteralPath (Join-Path $repoRoot "threshold/scripts/invoke-internal-review-twin.ps1") -Raw
    Assert-True -Condition ($twinText -match "Get-RevisionTextOrEmpty") -Name "internal review twin reads reviewer inputs from resolved head"
    Assert-True -Condition ($twinText -match "Get-RevisionTreeFileSetDigest") -Name "internal review twin binds evidence digests to resolved head"
    Assert-True -Condition ($twinText -match "Test-ReviewPathAgainstPattern") -Name "internal review twin mechanically matches forbidden path patterns"
    Assert-True -Condition ($twinText -match "forbiddenChangedPaths") -Name "internal review twin reports forbidden changed paths"
    Assert-True -Condition ($twinText -match "Get-ChangedPathsIncludingRenameEndpoints") -Name "internal review twin collects rename endpoints"
    Assert-True -Condition ($twinText -match "git diff --name-status -z -M") -Name "internal review twin uses NUL-delimited rename-aware changed path status"
    Assert-True -Condition ($twinText.Contains('-split "`0"')) -Name "internal review twin parses NUL-delimited name-status output"
    Assert-True -Condition ($twinText -match "HOLD_INTERNAL_FINDINGS") -Name "internal review twin holds on P2 findings"
    Assert-True -Condition ($twinText -match "java text block state decodes unicode quote delimiters") -Name "internal review twin requires Unicode delimiter hostile fixture"
    Assert-True -Condition ($twinText -match "java text block state splits unicode-produced line terminators") -Name "internal review twin requires Unicode line-terminator hostile fixture"
    Assert-True -Condition ($twinText -match "java unicode escape translation skips ineligible contiguous backslash escape") -Name "internal review twin requires ineligible Unicode escape hostile fixture"
    Assert-True -Condition ($twinText -match "Nested ordinary-comment content deliberately") -Name "internal review twin requires nested ordinary block-comment Javadoc hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state rejects target line with code after terminator") -Name "internal review twin requires Javadoc terminator suffix hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state preserves ordinary comment opened after text block close") -Name "internal review twin requires text-block closing suffix hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state rejects preformatted Javadoc content") -Name "internal review twin requires preformatted Javadoc hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state rejects same-line preformatted Javadoc content") -Name "internal review twin requires same-line preformatted Javadoc hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state treats line-end pre tag as preformatted opener") -Name "internal review twin requires line-end pre tag hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state preserves source-order pre tag transitions") -Name "internal review twin requires source-order pre tag hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state ignores pre markers inside inline code tags") -Name "internal review twin requires inline Javadoc pre marker hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state preserves inline tag depth across lines") -Name "internal review twin requires multiline inline-tag hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state ignores pre markers inside HTML comments") -Name "internal review twin requires HTML-comment Javadoc pre marker hostile fixture"
    Assert-True -Condition ($twinText -match "java javadoc lexical state preserves pre state from incoming HTML comment context") -Name "internal review twin requires incoming HTML-comment-state hostile fixture"
    Assert-True -Condition ($twinText -match "git merge-base") -Name "internal review twin computes patch from merge base"
    Assert-True -Condition ($twinText -match "patchBaseHead") -Name "internal review twin materializes patch base head"
    Assert-True -Condition ($twinText -match "run-next-slice revalidates current Javadoc context for prepared candidates") -Name "internal review twin requires single-slice revalidation fixture"
    Assert-True -Condition ($twinText -match "run-next-slice revalidates active comment wrap threshold") -Name "internal review twin requires single-slice threshold fixture"
    Assert-True -Condition ($twinText -match "run-next-batch rejects same-file line marker candidates in one batch") -Name "internal review twin requires same-file batch line-marker fixture"
    Assert-True -Condition ($twinText -match "run-next-batch uses shared discovery comment wrap predicate") -Name "internal review twin requires batch shared split predicate fixture"
    Assert-True -Condition ($twinText -match "run-next-batch preserves final newline when comment wrap rewrites file") -Name "internal review twin requires final-newline preservation fixture"
    Assert-True -Condition ($twinText -match "run-next-slice revalidates conservative comment split point before selection") -Name "internal review twin requires single-slice split predicate fixture"
    Assert-True -Condition ($twinText -match "run-next-slice preserves final newline when comment wrap rewrites file") -Name "internal review twin requires single-slice formatting preservation fixture"

    Write-Host "internalReviewTwinTests=passed"
}
finally {
    Set-Location $originalLocation
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
