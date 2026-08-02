[CmdletBinding()]
param(
    [string] $BaseRef = "main",
    [string] $HeadRef = "HEAD",
    [string] $Repository = "formatunitedandreas-code/spring-framework-petclinic",
    [string] $OutputPath = "",
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Get-StringSha256Lower {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileDigestOrEmpty {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-RevisionTextOrEmpty {
    param([string] $Revision, [string] $Path)

    $repoPath = $Path -replace "\\", "/"
    $text = @(& git show "$Revision`:$repoPath" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    return ($text -join "`n")
}

function Get-RevisionFileDigestOrEmpty {
    param([string] $Revision, [string] $Path)

    $text = Get-RevisionTextOrEmpty -Revision $Revision -Path $Path
    if ([string]::IsNullOrEmpty($text)) {
        return ""
    }
    return Get-StringSha256Lower -Text $text
}

function Get-RevisionTreeFileSetDigest {
    param([string] $Revision, [string] $RootPath)

    $repoRootPath = $RootPath -replace "\\", "/"
    $paths = @(& git ls-tree -r --name-only $Revision -- $repoRootPath 2>$null | Sort-Object)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) {
        return Get-StringSha256Lower -Text ""
    }
    $basis = @(
        $paths | ForEach-Object {
            $path = [string]$_
            "${path}:$(Get-RevisionFileDigestOrEmpty -Revision $Revision -Path $path)"
        }
    ) -join "`n"
    return Get-StringSha256Lower -Text $basis
}

function Test-ReviewPathAgainstPattern {
    param([string] $Path, [string] $Pattern)

    $normalizedPath = $Path -replace "\\", "/"
    $normalizedPattern = $Pattern -replace "\\", "/"
    return [System.Management.Automation.WildcardPattern]::new($normalizedPattern, "IgnoreCase").IsMatch($normalizedPath)
}

function Resolve-GitRevision {
    param([string] $Revision)
    $value = (& git rev-parse $Revision 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Unable to resolve git revision '$Revision'."
    }
    return ([string]$value).Trim()
}

function New-Finding {
    param(
        [string] $ReviewerId,
        [string] $Category,
        [string] $Severity,
        [string] $Title,
        [string[]] $AffectedPaths,
        [string[]] $ViolatedPredicates,
        [string] $Description
    )

    $basis = @($ReviewerId, $Category, $Severity, $Title, ($AffectedPaths -join ","), ($ViolatedPredicates -join ","), $Description) -join "|"
    return [ordered]@{
        schemaVersion = "InternalReviewFindingV0_1"
        findingId = "irf-" + (Get-StringSha256Lower -Text $basis).Substring(0, 16)
        reviewerId = $ReviewerId
        reviewerVersion = "v0_1"
        category = $Category
        severity = $Severity
        confidence = "HIGH"
        title = $Title
        description = $Description
        affectedPaths = @($AffectedPaths)
        affectedLocations = @()
        violatedPredicates = @($ViolatedPredicates)
        evidenceReferences = @()
        reproductionSteps = @()
        counterexampleFixture = ""
        recommendedDisposition = "HOLD_INTERNAL_FINDINGS"
        authorizing = $false
    }
}

function New-ReviewerResult {
    param(
        [string] $ReviewerId,
        [object[]] $Findings,
        [string[]] $CoverageClaims,
        [string[]] $UnsupportedSurfaces = @()
    )

    $status = if (@($Findings).Count -gt 0) {
        "FINDING"
    }
    elseif (@($UnsupportedSurfaces).Count -gt 0) {
        "HOLD_UNSUPPORTED_REVIEW_SURFACE"
    }
    else {
        "PASS_NO_FINDING"
    }
    $payload = [ordered]@{
        schemaVersion = "InternalReviewResultV0_1"
        reviewerId = $ReviewerId
        status = $status
        findings = @($Findings)
        coverageClaims = @($CoverageClaims)
        unsupportedSurfaces = @($UnsupportedSurfaces)
        knownUnknowns = @()
        authorizing = $false
    }
    $payload.reviewDigest = Get-StringSha256Lower -Text ($payload | ConvertTo-Json -Depth 12 -Compress)
    return $payload
}

$headSha = Resolve-GitRevision -Revision $HeadRef
$baseHead = Resolve-GitRevision -Revision $BaseRef
$patchBaseHead = (& git merge-base $baseHead $headSha 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$patchBaseHead)) {
    throw "Unable to compute merge base for $baseHead and $headSha."
}
$patchBaseHead = ([string]$patchBaseHead).Trim()
$treeDigest = Resolve-GitRevision -Revision "$headSha^{tree}"
$changedPaths = @(& git diff --name-only "$patchBaseHead..$headSha" | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to compute changed paths for $patchBaseHead..$headSha."
}
$patchText = @(& git diff --binary "$patchBaseHead..$headSha") -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "Unable to compute patch for $patchBaseHead..$headSha."
}

$reviewSubject = [ordered]@{
    schemaVersion = "ThresholdReviewSubjectV0_1"
    reviewSubjectId = "trs-" + (Get-StringSha256Lower -Text "$Repository|$BaseRef|$baseHead|$HeadRef|$headSha").Substring(0, 16)
    repository = $Repository
    baseRef = $BaseRef
    baseHead = $baseHead
    patchBaseHead = $patchBaseHead
    headRef = $HeadRef
    headSha = $headSha
    treeDigest = $treeDigest
    patchDigest = Get-StringSha256Lower -Text $patchText
    changedPaths = @($changedPaths)
    changedPathDigest = Get-StringSha256Lower -Text (@($changedPaths) -join "`n")
    workOrderDigest = ""
    authorityEnvelopeDigest = ""
    candidatePocketDigest = Get-RevisionFileDigestOrEmpty -Revision $headSha -Path "threshold/candidate-pocket/current.json"
    discoveryEvidenceDigest = Get-RevisionTreeFileSetDigest -Revision $headSha -RootPath "threshold/discovery-evidence"
    receiptSetDigest = Get-RevisionTreeFileSetDigest -Revision $headSha -RootPath "threshold/receipts"
    capabilityKgDigest = Get-RevisionFileDigestOrEmpty -Revision $headSha -Path "threshold/kgs/capability-kg.json"
    fidelityKgDigest = Get-RevisionFileDigestOrEmpty -Revision $headSha -Path "threshold/kgs/fidelity-kg.json"
    semanticKgDigest = ""
    expectedCandidateClasses = @("comment_wrap_cleanup")
    expectedTransformationClasses = @("comment_wrap_cleanup")
    forbiddenPaths = @("src/main/java/**", "pom.xml", ".github/**")
    forbiddenActions = @("product_source_mutation", "dependency_change", "workflow_change", "merge_authorization")
    requiredValidations = @(
        "threshold/scripts/test-candidate-class-provenance.ps1",
        "threshold/scripts/test-discovery-canary.ps1",
        "threshold/scripts/test-local-review-simulation.ps1",
        "threshold/scripts/test-pr-governance.ps1 -BaseRef main"
    )
    createdAt = (Get-Date).ToUniversalTime().ToString("o")
    expiresAt = (Get-Date).ToUniversalTime().AddHours(6).ToString("o")
}
$reviewSubject.reviewSubjectDigest = Get-StringSha256Lower -Text ($reviewSubject | ConvertTo-Json -Depth 12 -Compress)

$candidateProvenanceText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/lib/candidate-class-provenance.ps1"
$runNextBatchText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/run-next-batch.ps1"
$runNextSliceText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/run-next-slice.ps1"
$candidateTestText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/test-candidate-class-provenance.ps1"
$discoveryCanaryText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/test-discovery-canary.ps1"
$canaryCommentModelText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic/model/CanaryCommentModel.java"
$internalReviewTwinText = Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/invoke-internal-review-twin.ps1"

$runtimeFindings = @()
if ($candidateProvenanceText -notmatch 'function Remove-ThresholdJavaLineCommentOutsideLiteral') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Java line-comment parsing is not literal-aware" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_line_comment_detection_respects_string_literals") -Description "The text-block scanner has no canonical line-comment parser that distinguishes // inside Java string or char literals."
}
if ($candidateProvenanceText -match '\.IndexOf\("//"\)') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Raw // detection can hide text-block delimiters" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_line_comment_detection_respects_string_literals") -Description "A raw IndexOf(\"//\") can treat URL literals such as http://x as comments before a real text-block opener."
}
if ($candidateProvenanceText -notmatch 'Get-ThresholdJavaTextBlockDelimiterCount') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Text-block delimiter parser does not reject escaped quote characters" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_text_block_delimiters_must_be_unescaped") -Description "The text-block scanner must count only lexically valid, unescaped triple-quote delimiters."
}
if ($candidateProvenanceText -notmatch 'Remove-ThresholdJavaCommentsOutsideLiteral') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Java block-comment text-block delimiters are not ignored" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("block_comment_text_block_delimiters_ignored") -Description "The text-block scanner must ignore triple-quote text inside Java block comments before counting delimiters."
}
if ($candidateProvenanceText -notmatch 'Convert-ThresholdJavaUnicodeEscapes') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Java Unicode escapes are not decoded before text-block tracking" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_escapes_decoded_before_text_block_tracking") -Description "Java performs Unicode translation before tokenization, so the local text-block scanner must decode eligible Unicode escapes before delimiter tracking."
}
if ($candidateProvenanceText -notmatch 'Split-ThresholdJavaUnicodeTranslatedLine') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Java Unicode-produced line terminators are not split before text-block tracking" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_line_terminators_split_before_text_block_tracking") -Description "Java performs Unicode translation before tokenization, so Unicode-produced line terminators must be split into logical lines before comment and text-block delimiter tracking."
}
if ($candidateProvenanceText -notmatch 'Test-ThresholdJavaUnicodeEscapeBackslashIsEligible') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P1" -Title "Java Unicode escape translation ignores eligibility" -AffectedPaths @("threshold/scripts/lib/candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_escape_translation_respects_backslash_eligibility") -Description "Java Unicode translation must apply the contiguous-backslash eligibility rule before replacing a Unicode escape."
}
if ($candidateTestText -notmatch 'java text block state ignores double slash inside string literal') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing URL-literal text-block regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("hostile_runtime_literal_fixture_present") -Description "The internal test corpus does not exercise a URL literal before a Java text-block opener."
}
if ($candidateTestText -notmatch 'java text block state ignores escaped triple quote characters') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing escaped text-block delimiter regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("hostile_runtime_literal_fixture_present") -Description "The internal test corpus does not exercise escaped triple quote characters inside a Java text block."
}
if ($candidateTestText -notmatch 'java text block state ignores block-comment triple quote delimiter') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing block-comment text-block delimiter regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("block_comment_text_block_delimiters_ignored") -Description "The internal test corpus does not exercise a block comment containing triple quotes before a Java text block."
}
if ($candidateTestText -notmatch 'java text block state decodes unicode quote delimiters') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing Unicode text-block delimiter regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_escapes_decoded_before_text_block_tracking") -Description "The internal test corpus does not exercise Unicode-escaped Java text-block delimiters."
}
if ($candidateTestText -notmatch 'java text block state splits unicode-produced line terminators') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing Unicode line-terminator text-block regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_line_terminators_split_before_text_block_tracking") -Description "The internal test corpus does not exercise Unicode-produced Java line terminators before text-block delimiters."
}
if ($candidateTestText -notmatch 'java unicode escape translation skips ineligible contiguous backslash escape') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing ineligible Unicode escape regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("java_unicode_escape_translation_respects_backslash_eligibility") -Description "The internal test corpus does not exercise an ineligible Java Unicode escape preceded by an odd contiguous backslash count."
}if ($candidateTestText -notmatch 'java javadoc lexical state rejects target line with code after terminator') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing Javadoc terminator target-line regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("javadoc_target_line_scanned_through_terminator") -Description "The internal test corpus does not exercise a Javadoc candidate line that closes the comment and then continues with Java code."
}
if ($candidateTestText -notmatch 'java javadoc lexical state preserves ordinary comment opened after text block close') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Missing text-block closing suffix block-comment regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("text_block_closing_suffix_comment_state_preserved") -Description "The internal test corpus does not exercise an ordinary block comment opened in the suffix after a Java text-block closing delimiter."
}
if ($canaryCommentModelText -notmatch 'http://x') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Discovery Canary lacks URL-literal text-block hostile fixture" -AffectedPaths @("threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic/model/CanaryCommentModel.java") -ViolatedPredicates @("discovery_canary_runtime_literal_surface_present") -Description "The Discovery Canary does not bind the URL-literal plus text-block delimiter surface."
}
if ($canaryCommentModelText -notmatch 'Nested ordinary-comment content deliberately') {
    $runtimeFindings += New-Finding -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Category "runtime_literal" -Severity "P2" -Title "Discovery Canary lacks nested ordinary block-comment Javadoc hostile fixture" -AffectedPaths @("threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic/model/CanaryCommentModel.java") -ViolatedPredicates @("ordinary_block_comment_nested_javadoc_opener_not_promoted") -Description "The Discovery Canary does not bind an ordinary block comment that contains a nested /** marker and a wrappable star-line."
}

$candidateFindings = @()
if ($runNextBatchText -match '\$line\.Length -le 120') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P1" -Title "Batch eligibility is stricter than discovery threshold" -AffectedPaths @("threshold/scripts/run-next-batch.ps1") -ViolatedPredicates @("batch_comment_wrap_uses_discovery_threshold") -Description "comment_wrap_cleanup batch eligibility still hardcodes the baseline threshold 120 instead of the active lease commentWrapThreshold."
}
if ($runNextBatchText -notmatch 'Get-CommentWrapThreshold') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P1" -Title "Batch runner does not bind active comment wrap threshold" -AffectedPaths @("threshold/scripts/run-next-batch.ps1") -ViolatedPredicates @("batch_comment_wrap_uses_discovery_threshold") -Description "The batch runner lacks a canonical threshold resolver for comment_wrap_cleanup."
}
if ($runNextBatchText -notmatch 'Test-BatchJavadocCommentLine') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Batch runner does not revalidate current Javadoc context" -AffectedPaths @("threshold/scripts/run-next-batch.ps1") -ViolatedPredicates @("batch_comment_wrap_revalidates_current_javadoc_context") -Description "Prepared batch candidates must be revalidated against the current file's Javadoc and text-block state before mutation."
}
if ($runNextSliceText -notmatch 'Test-SliceJavadocCommentLine') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Slice runner does not revalidate current Javadoc context" -AffectedPaths @("threshold/scripts/run-next-slice.ps1") -ViolatedPredicates @("slice_comment_wrap_revalidates_current_javadoc_context") -Description "Prepared single-slice candidates must be revalidated against the current file's Javadoc and text-block state before mutation."
}
if ($runNextSliceText -notmatch 'Get-CommentWrapThreshold' -or $runNextSliceText -notmatch 'comment_wrap_threshold_not_met') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Slice runner does not revalidate active comment wrap threshold" -AffectedPaths @("threshold/scripts/run-next-slice.ps1") -ViolatedPredicates @("slice_comment_wrap_uses_discovery_threshold") -Description "Prepared single-slice candidates must be revalidated against the active lease commentWrapThreshold before selection and immediately before mutation."
}
if ($runNextBatchText -notmatch 'selectedLineCandidatePaths' -or $runNextBatchText -notmatch 'same_file_line_marker_rebinding_required') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P1" -Title "Batch runner can apply stale same-file line markers" -AffectedPaths @("threshold/scripts/run-next-batch.ps1") -ViolatedPredicates @("batch_comment_wrap_rejects_same_file_line_markers") -Description "A batch must not execute multiple line-based comment_wrap_cleanup candidates in the same file without bottom-up ordering or marker rebinding."
}
if ($candidateTestText -notmatch 'run-next-batch derives comment wrap eligibility from lease threshold') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Batch threshold coherence is not regression-tested" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("batch_comment_wrap_uses_discovery_threshold") -Description "The local reviewer cannot prove the batch runner remains aligned with discovery thresholds."
}
if ($candidateTestText -notmatch 'run-next-batch revalidates current Javadoc context for prepared candidates') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Missing batch Javadoc revalidation regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("batch_comment_wrap_revalidates_current_javadoc_context") -Description "The local reviewer cannot prove prepared batch candidates revalidate current Javadoc context."
}
if ($candidateTestText -notmatch 'run-next-slice revalidates current Javadoc context for prepared candidates') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Missing slice Javadoc revalidation regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("slice_comment_wrap_revalidates_current_javadoc_context") -Description "The local reviewer cannot prove prepared single-slice candidates revalidate current Javadoc context."
}
if ($candidateTestText -notmatch 'run-next-slice revalidates active comment wrap threshold') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Missing slice threshold revalidation regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("slice_comment_wrap_uses_discovery_threshold") -Description "The local reviewer cannot prove prepared single-slice candidates revalidate the active commentWrapThreshold."
}
if ($candidateTestText -notmatch 'run-next-batch rejects same-file line marker candidates in one batch') {
    $candidateFindings += New-Finding -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Category "candidate_class" -Severity "P2" -Title "Missing same-file batch line-marker regression" -AffectedPaths @("threshold/scripts/test-candidate-class-provenance.ps1") -ViolatedPredicates @("batch_comment_wrap_rejects_same_file_line_markers") -Description "The local reviewer cannot prove batch comment_wrap_cleanup avoids stale same-file line markers."
}

$fixtureFindings = @()
foreach ($requiredPattern in @("missingTrainerExpectationRejected=true", "declaredTrainerExpectationCoverageRequired=true", "declaredExecutionModeExpectationCoverageRequired=true", "requiredClassDeduplicationCountedOnce=true")) {
    if ($discoveryCanaryText -notmatch [regex]::Escape($requiredPattern)) {
        $fixtureFindings += New-Finding -ReviewerId "threshold.fixture_integrity_reviewer.v0_1" -Category "fixture_integrity" -Severity "P2" -Title "Discovery Canary fixture reason binding is incomplete" -AffectedPaths @("threshold/scripts/test-discovery-canary.ps1") -ViolatedPredicates @("negative_fixture_reason_isolated") -Description "Missing fixture-integrity signal '$requiredPattern'."
    }
}

$scopeFindings = @()
if (($reviewSubject.forbiddenActions -notcontains "merge_authorization") -or ($reviewSubject.forbiddenActions -notcontains "product_source_mutation")) {
    $scopeFindings += New-Finding -ReviewerId "threshold.scope_authority_reviewer.v0_1" -Category "scope_authority" -Severity "P1" -Title "Review subject does not explicitly forbid effects" -AffectedPaths @("threshold/scripts/invoke-internal-review-twin.ps1") -ViolatedPredicates @("reviewer_authorizing_false") -Description "Internal review subjects must make forbidden effects explicit."
}
$forbiddenChangedPaths = @(
    foreach ($path in $changedPaths) {
        foreach ($pattern in $reviewSubject.forbiddenPaths) {
            if (Test-ReviewPathAgainstPattern -Path $path -Pattern $pattern) {
                $path
                break
            }
        }
    }
)
if ($forbiddenChangedPaths.Count -gt 0) {
    $scopeFindings += New-Finding -ReviewerId "threshold.scope_authority_reviewer.v0_1" -Category "scope_authority" -Severity "P1" -Title "Reviewed range changes declared forbidden paths" -AffectedPaths $forbiddenChangedPaths -ViolatedPredicates @("declared_forbidden_paths_mechanically_enforced") -Description "Internal review subject declares forbidden paths, and the reviewed exact-head range changes them: $($forbiddenChangedPaths -join ', ')."
}

$evidenceFindings = @()
if ($reviewSubject.headSha -ne $headSha -or [string]::IsNullOrWhiteSpace($reviewSubject.patchDigest) -or [string]::IsNullOrWhiteSpace($reviewSubject.changedPathDigest)) {
    $evidenceFindings += New-Finding -ReviewerId "threshold.evidence_causality_reviewer.v0_1" -Category "evidence_causality" -Severity "P1" -Title "Review subject is not exact-head bound" -AffectedPaths @("threshold/scripts/invoke-internal-review-twin.ps1") -ViolatedPredicates @("review_subject_exact_head_bound") -Description "The review subject failed exact-head or digest binding."
}
if ($candidateProvenanceText -ne (Get-RevisionTextOrEmpty -Revision $headSha -Path "threshold/scripts/lib/candidate-class-provenance.ps1")) {
    $evidenceFindings += New-Finding -ReviewerId "threshold.evidence_causality_reviewer.v0_1" -Category "evidence_causality" -Severity "P1" -Title "Reviewer inputs are not bound to resolved head" -AffectedPaths @("threshold/scripts/invoke-internal-review-twin.ps1") -ViolatedPredicates @("reviewer_inputs_bound_to_resolved_head") -Description "Internal reviewer input text must be loaded from the resolved reviewed head, not from the ambient checkout."
}
if ($internalReviewTwinText -notmatch 'git merge-base' -or $internalReviewTwinText -notmatch 'patchBaseHead') {
    $evidenceFindings += New-Finding -ReviewerId "threshold.evidence_causality_reviewer.v0_1" -Category "evidence_causality" -Severity "P2" -Title "Review patch is not computed from merge base" -AffectedPaths @("threshold/scripts/invoke-internal-review-twin.ps1") -ViolatedPredicates @("review_patch_bound_to_merge_base") -Description "Internal review changed paths and patch digest must be computed from the base/head merge base, not from a tip-to-tip two-dot comparison."
}

$results = @(
    (New-ReviewerResult -ReviewerId "threshold.runtime_literal_reviewer.v0_1" -Findings $runtimeFindings -CoverageClaims @("java_text_block_content_not_comment_wrap_candidate", "java_line_comment_detection_respects_string_literals", "java_text_block_delimiters_must_be_unescaped", "block_comment_text_block_delimiters_ignored", "ordinary_block_comment_not_promoted_as_javadoc", "ordinary_block_comment_nested_javadoc_opener_not_promoted", "java_unicode_escapes_decoded_before_text_block_tracking", "java_unicode_line_terminators_split_before_text_block_tracking", "java_unicode_escape_translation_respects_backslash_eligibility", "javadoc_target_line_scanned_through_terminator", "text_block_closing_suffix_comment_state_preserved")),
    (New-ReviewerResult -ReviewerId "threshold.candidate_class_reviewer.v0_1" -Findings $candidateFindings -CoverageClaims @("candidate_class_provenance_chain_bound", "observed_diff_class_matches_candidate_class", "batch_comment_wrap_uses_discovery_threshold", "batch_comment_wrap_revalidates_current_javadoc_context", "batch_comment_wrap_rejects_same_file_line_markers", "slice_comment_wrap_revalidates_current_javadoc_context", "slice_comment_wrap_uses_discovery_threshold")),
    (New-ReviewerResult -ReviewerId "threshold.fixture_integrity_reviewer.v0_1" -Findings $fixtureFindings -CoverageClaims @("negative_fixture_reason_isolated", "missing_trainer_fixture_keeps_execution_mode_valid", "duplicate_required_class_counted_once")),
    (New-ReviewerResult -ReviewerId "threshold.scope_authority_reviewer.v0_1" -Findings $scopeFindings -CoverageClaims @("reviewer_authorizing_false", "internal_review_does_not_create_push_or_merge_authority", "declared_forbidden_paths_mechanically_enforced")),
    (New-ReviewerResult -ReviewerId "threshold.evidence_causality_reviewer.v0_1" -Findings $evidenceFindings -CoverageClaims @("review_subject_exact_head_bound", "reviewer_inputs_bound_to_resolved_head", "patch_digest_bound_to_base_and_head", "changed_path_digest_bound", "review_patch_bound_to_merge_base"))
)

$findingSet = @($results | ForEach-Object { @($_.findings) } | ForEach-Object { $_ })
$unsupportedSurfaceCount = @($results | ForEach-Object { @($_.unsupportedSurfaces).Count } | Measure-Object -Sum).Sum
if ($null -eq $unsupportedSurfaceCount) { $unsupportedSurfaceCount = 0 }
$highestSeverity = "NONE"
foreach ($severity in @("P0", "P1", "P2", "P3")) {
    if (@($findingSet | Where-Object { [string]$_.severity -eq $severity }).Count -gt 0) {
        $highestSeverity = $severity
        break
    }
}
$recommendedControlOutcome = if (@($findingSet | Where-Object { [string]$_.severity -eq "P0" }).Count -gt 0) {
    "BLOCK_AUTHORITY_VIOLATION"
}
elseif (@($findingSet | Where-Object { [string]$_.severity -eq "P1" }).Count -gt 0) {
    "HOLD_INTERNAL_FINDINGS"
}
elseif (@($findingSet).Count -gt 0) {
    "HOLD_INTERNAL_FINDINGS"
}
elseif ([int]$unsupportedSurfaceCount -gt 0) {
    "HOLD_INSUFFICIENT_REVIEW_COVERAGE"
}
else {
    "PROCEED_TO_EXTERNAL_HOLDOUT"
}

$twin = [ordered]@{
    schemaVersion = "InternalReviewTwinV0_1"
    reviewSubjectId = $reviewSubject.reviewSubjectId
    reviewSubject = $reviewSubject
    reviewerResults = @($results)
    findingSet = @($findingSet)
    findingSetDigest = Get-StringSha256Lower -Text (@($findingSet | ConvertTo-Json -Depth 12 -Compress) -join "")
    coverageComplete = ([int]$unsupportedSurfaceCount -eq 0)
    unsupportedSurfaceCount = [int]$unsupportedSurfaceCount
    highestSeverity = $highestSeverity
    recommendedControlOutcome = $recommendedControlOutcome
    authorizing = $false
    externalCodexReviewStillRequired = $true
    denyOnlyCalibrationRequiredForExternalMiss = $true
    positiveEffectAuthorized = $false
}
$twin.reviewDigest = Get-StringSha256Lower -Text ($twin | ConvertTo-Json -Depth 16 -Compress)

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }
    $twin | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath
}

if (-not $Quiet) {
    Write-Host "internalReviewTwin=completed"
    Write-Host "reviewSubjectId=$($reviewSubject.reviewSubjectId)"
    Write-Host "headSha=$headSha"
    Write-Host "findingCount=$(@($findingSet).Count)"
    Write-Host "highestSeverity=$highestSeverity"
    Write-Host "coverageComplete=$($twin.coverageComplete)"
    Write-Host "recommendedControlOutcome=$recommendedControlOutcome"
    Write-Host "externalCodexReviewStillRequired=true"
}

if ($recommendedControlOutcome -eq "BLOCK_AUTHORITY_VIOLATION" -or $recommendedControlOutcome -eq "HOLD_INTERNAL_FINDINGS" -or $recommendedControlOutcome -eq "HOLD_INSUFFICIENT_REVIEW_COVERAGE") {
    exit 1
}
