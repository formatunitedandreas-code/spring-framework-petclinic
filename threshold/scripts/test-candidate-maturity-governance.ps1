[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$gate = Get-Content "threshold/gates/auto-patchable-candidate-classes.json" -Raw | ConvertFrom-Json
$batchApproved = @($gate.batchReceiptMode.approvedCandidateClasses | ForEach-Object { [string]$_.candidateClass })
if ($batchApproved -contains "comment_wrap_cleanup") {
    throw "comment_wrap_cleanup_must_not_be_batch_auto_patchable"
}

$approvedAuto = @($gate.approvedAutoPatchableCandidateClasses | ForEach-Object { [string]$_.candidateClass })
foreach ($heldClass in @("comment_wrap_cleanup", "line_comment_wrap_cleanup")) {
    if ($approvedAuto -contains $heldClass) {
        throw "held_comment_class_must_not_be_auto_patchable=$heldClass"
    }
}

$held = @($gate.batchReceiptMode.heldCandidateClasses | ForEach-Object { [string]$_.candidateClass })
foreach ($heldClass in @("comment_wrap_cleanup", "line_comment_wrap_cleanup")) {
    if ($held -notcontains $heldClass) {
        throw "held_comment_class_missing=$heldClass"
    }
}

$report = Get-Content "threshold/trainer/training-report.json" -Raw | ConvertFrom-Json
$lineCommentDecision = $report.decisions | Where-Object { [string]$_.candidateClass -eq "line_comment_wrap_cleanup" } | Select-Object -First 1
if (-not $lineCommentDecision -or [string]$lineCommentDecision.decision -ne "reviewOnly") {
    throw "line_comment_wrap_cleanup_trainer_decision_must_be_reviewOnly"
}

$capabilityKg = Get-Content "threshold/kgs/capability-kg.json" -Raw | ConvertFrom-Json
$lineCommentCapability = $capabilityKg.nodes | Where-Object { [string]$_.id -eq "capability:line_comment_wrap_cleanup" } | Select-Object -First 1
if (-not $lineCommentCapability -or [string]$lineCommentCapability.trainerDecision -ne "reviewOnly") {
    throw "line_comment_wrap_cleanup_capability_must_be_reviewOnly"
}

$discoverText = Get-Content "threshold/scripts/discover-candidates.ps1" -Raw
foreach ($requiredMarker in @(
    "threshold.candidate-maturity-admission.v0.1",
    "threshold.candidate-twin-delta-evidence.v0.1",
    "candidate_maturity:comment_cleanup_requires_policy_bound_quality_objective",
    "candidate_maturity:twin_delta_quality_fidelity_failed",
    "candidate_maturity:policy_not_bound",
    "candidate_maturity:semantic_fidelity_not_evaluated",
    "execution stability is not quality objective verification",
    "discovery visibility is not semantic fidelity proof",
    "synthetic target policy evidence must not promote candidate admission",
    "Somnium may demote candidate maturity but may not promote missing evidence, policy, or quality"
)) {
    if ($discoverText -notmatch [regex]::Escape($requiredMarker)) {
        throw "candidate_maturity_discovery_marker_missing=$requiredMarker"
    }
}

$tempPocket = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-candidate-maturity-governance-pocket.json"
if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
    -SourceRoot "threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic" `
    -PocketPath $tempPocket `
    -Limit 100
if ($LASTEXITCODE -ne 0) {
    throw "candidate_maturity_fixture_discovery_failed"
}
$pocket = Get-Content $tempPocket -Raw | ConvertFrom-Json
$commentCandidate = $pocket.candidates | Where-Object { [string]$_.candidateClass -eq "comment_wrap_cleanup" } | Select-Object -First 1
if (-not $commentCandidate) {
    throw "candidate_maturity_comment_fixture_missing"
}
if ([string]$commentCandidate.admission -ne "reviewOnly") {
    throw "candidate_maturity_comment_fixture_not_reviewOnly"
}
if (-not $commentCandidate.twinDelta -or [string]$commentCandidate.twinDelta.schemaVersion -ne "threshold.candidate-twin-delta-evidence.v0.1") {
    throw "candidate_maturity_twin_delta_missing"
}
if ($commentCandidate.twinDelta.semanticFidelity.behaviorPreserved -ne $false) {
    throw "candidate_maturity_semantic_fidelity_must_not_be_synthetic_pass"
}
if ([string]$commentCandidate.twinDelta.semanticFidelity.evidenceStatus -ne "not_evaluated") {
    throw "candidate_maturity_semantic_fidelity_status_must_be_not_evaluated"
}
if ($commentCandidate.twinDelta.qualityFidelity.canonicalityImproved -ne $false) {
    throw "candidate_maturity_quality_fidelity_expected_fail"
}
$repositoryCandidate = $pocket.candidates | Where-Object { [string]$_.candidateClass -eq "repository_readability_cleanup" } | Select-Object -First 1
if (-not $repositoryCandidate) {
    throw "candidate_maturity_repository_fixture_missing"
}
if ([string]$repositoryCandidate.admission -ne "reviewOnly") {
    throw "candidate_maturity_repository_fixture_must_remain_reviewOnly_without_core_evidence"
}
if ($repositoryCandidate.autoPatchable -ne $false) {
    throw "candidate_maturity_repository_fixture_must_not_be_autoPatchable_without_core_evidence"
}
if ($repositoryCandidate.twinDelta.targetTwin.policyRef) {
    throw "candidate_maturity_repository_fixture_must_not_synthesize_policy_ref"
}
if ([string]$repositoryCandidate.maturity.predicates.policyBound -ne "failed") {
    throw "candidate_maturity_repository_fixture_policy_must_not_pass_without_policy_ref"
}
if ([string]$repositoryCandidate.maturity.predicates.semanticRiskAcceptable -ne "not_evaluated") {
    throw "candidate_maturity_repository_fixture_semantic_risk_must_not_be_synthetic_pass"
}
if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}

$batchRunnerText = Get-Content "threshold/scripts/run-next-batch.ps1" -Raw
foreach ($requiredMarker in @(
    "Test-CandidateMaturityAutoPatchable",
    '$Candidate.PSObject.Properties["admission"]',
    '$Candidate.maturity.PSObject.Properties["admission"]'
)) {
    if ($batchRunnerText -notmatch [regex]::Escape($requiredMarker)) {
        throw "candidate_maturity_batch_guard_missing=$requiredMarker"
    }
}

Write-Host "candidateMaturityGovernance=passed"
