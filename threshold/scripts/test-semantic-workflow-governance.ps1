[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

$paths = Get-ThresholdSemanticRuntimePaths -RunId "test-run"
if ($paths.RuntimeRoot -ne "threshold/runtime") {
    throw "semantic_runtime_root_mismatch"
}
if ($paths.TwinDeltaPath -ne "threshold/runs/test-run/twin-delta.json") {
    throw "semantic_twin_delta_path_mismatch"
}

$scriptText = Get-Content (Join-Path $PSScriptRoot "run-next-slice.ps1") -Raw
if ($scriptText -notmatch "semantic_workorders_must_use_semantic_lane") {
    throw "legacy_runner_semantic_guard_missing"
}

$semanticRunnerText = Get-Content (Join-Path $PSScriptRoot "run-next-semantic-workorder.ps1") -Raw
if ($semanticRunnerText -notmatch "stop_authority_missing=semantic workorder execution requires SeniorRefactoringGovernor admission") {
    throw "semantic_runner_authority_stop_missing"
}

$deltaPlannerText = Get-Content (Join-Path $PSScriptRoot "plan-twin-delta.ps1") -Raw
if ($deltaPlannerText -notmatch "semantic_guardian_blocked") {
    throw "semantic_guardian_block_missing"
}

$fileEconomyText = Get-Content (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1") -Raw
if ($fileEconomyText -notmatch "semantic_file_economy_missing_required_file") {
    throw "semantic_file_economy_required_file_check_missing"
}
if ($fileEconomyText -notmatch "git ls-files --others --exclude-standard") {
    throw "semantic_file_economy_untracked_run_evidence_check_missing"
}
if ($fileEconomyText -notmatch "Get-ThresholdFileEconomyPolicy") {
    throw "semantic_file_economy_policy_loader_missing"
}
if ($fileEconomyText -notmatch "Get-ThresholdChangedLineCount") {
    throw "semantic_file_economy_untracked_line_count_missing"
}

$scopeDrainText = Get-Content (Join-Path $PSScriptRoot "run-until-scope-exhausted.ps1") -Raw
if ($scopeDrainText -notmatch '\[string\] \$EvidenceMode = "Compact"') {
    throw "scope_drain_compact_evidence_default_missing"
}
if ($scopeDrainText -notmatch "Save-CompactScopeDrainEvidence") {
    throw "scope_drain_compact_evidence_materialization_missing"
}
if ($scopeDrainText -notmatch "threshold/runtime/scope-drain/current") {
    throw "scope_drain_runtime_state_path_missing"
}
if ($scopeDrainText -notmatch 'branchFinalValidationPassed = \$false') {
    throw "scope_drain_aggregate_branch_final_validation_field_missing"
}

$prGovernanceText = Get-Content (Join-Path $PSScriptRoot "test-pr-governance.ps1") -Raw
if ($prGovernanceText -notmatch "Assert-ThresholdSemanticEvidenceFileEconomy") {
    throw "pr_governance_file_economy_enforcement_missing"
}
if ($prGovernanceText -notmatch "Source commit covered by aggregate Threshold receipt") {
    throw "pr_governance_aggregate_receipt_coverage_missing"
}
if ($prGovernanceText -notmatch "AllowedValidationResults") {
    throw "pr_governance_validation_status_allowlist_missing"
}
if ($prGovernanceText -notmatch "PublicationPreflight") {
    throw "pr_governance_publication_preflight_missing"
}
if ($prGovernanceText -notmatch "stop_authority_missing=one-shot publication authority required") {
    throw "pr_governance_one_shot_authority_stop_missing"
}

$publicationPreflightText = Get-Content (Join-Path $PSScriptRoot "test-publication-preflight-fixtures.ps1") -Raw
foreach ($requiredMarker in @(
    "missing-authority",
    "wrong-head-authority",
    "wrong-branch-authority",
    "expired-authority",
    "consumed-authority",
    "stale-review-head",
    "open-p1-p2-findings",
    "core-cli-missing",
    "multiple-json-values",
    "missing-typed-fields",
    "unknown-core-field",
    "validator-evaluated-different-head",
    "typed-publication-blocked-reason-string-allowed",
    "reason-renaming-does-not-decide",
    "reason-ablation-does-not-decide",
    "merge-authority-not-publication",
    "post-cli-head-detached"
)) {
    if ($publicationPreflightText -notmatch $requiredMarker) {
        throw "publication_preflight_fixture_missing=$requiredMarker"
    }
}

$isolatedToctouText = Get-Content (Join-Path $PSScriptRoot "test-publication-toctou-isolated-fixture.ps1") -Raw
if ($isolatedToctouText -notmatch "isolated-post-cli-head-detached") {
    throw "publication_toctou_isolated_fixture_missing"
}

$reasonAuditText = Get-Content (Join-Path $PSScriptRoot "audit-publication-reason-boundary.ps1") -Raw
foreach ($requiredMarker in @(
    "nonAuthorizing",
    "effectDecisions.publication.allowed",
    "failedConstraintIds as report/projection data",
    "reason audit is not publication authority",
    "allowedEffects = @(""observe"", ""shadowIntegration"")",
    "Somnium shadow_ready is technical observation readiness only",
    "Somnium may only affect observe and shadowIntegration in this adapter lane",
    "SomniumDecision <= GuardianDecision <= AuthorityDecision is an ordering invariant",
    "Somnium outputs may not return as training truth through telemetry, Chunky bias, KG projection, or training artifacts without grounding and independent review",
    "Publication and merge readiness remain false until separate exact-head authority exists",
    "publication remains bound to typed effect decisions"
)) {
    if ($reasonAuditText -notmatch [regex]::Escape($requiredMarker)) {
        throw "reason_audit_boundary_marker_missing=$requiredMarker"
    }
}

$candidateMaturityText = Get-Content (Join-Path $PSScriptRoot "test-candidate-maturity-governance.ps1") -Raw
foreach ($requiredMarker in @(
    "comment_wrap_cleanup_must_not_be_batch_auto_patchable",
    "line_comment_wrap_cleanup_trainer_decision_must_be_reviewOnly",
    "Test-CandidateMaturityAutoPatchable"
)) {
    if ($candidateMaturityText -notmatch [regex]::Escape($requiredMarker)) {
        throw "candidate_maturity_governance_marker_missing=$requiredMarker"
    }
}

$completeSliceText = Get-Content (Join-Path $PSScriptRoot "complete-slice.ps1") -Raw
if ($completeSliceText -notmatch "CompactEvidence") {
    throw "complete_slice_compact_evidence_mode_missing"
}

$gitignore = Get-Content ".gitignore" -Raw
if ($gitignore -notmatch "threshold/runtime/") {
    throw "semantic_runtime_gitignore_missing"
}

Write-Host "semanticWorkflowGovernance=passed"
