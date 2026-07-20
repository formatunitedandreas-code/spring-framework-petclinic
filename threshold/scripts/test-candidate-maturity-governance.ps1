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
    "candidate_maturity:comment_cleanup_requires_policy_bound_quality_objective",
    "execution stability is not quality objective verification",
    "Somnium may demote candidate maturity but may not promote missing evidence, policy, or quality"
)) {
    if ($discoverText -notmatch [regex]::Escape($requiredMarker)) {
        throw "candidate_maturity_discovery_marker_missing=$requiredMarker"
    }
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
