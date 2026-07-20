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

$gitignore = Get-Content ".gitignore" -Raw
if ($gitignore -notmatch "threshold/runtime/") {
    throw "semantic_runtime_gitignore_missing"
}

Write-Host "semanticWorkflowGovernance=passed"
