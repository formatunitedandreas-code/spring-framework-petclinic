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

$gitignore = Get-Content ".gitignore" -Raw
if ($gitignore -notmatch "threshold/runtime/") {
    throw "semantic_runtime_gitignore_missing"
}

Write-Host "semanticWorkflowGovernance=passed"
