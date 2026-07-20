[CmdletBinding()]
param(
    [string] $RunId = "",
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

$statusLines = @(git status --porcelain)
if ($statusLines.Count -gt 0) {
    throw "stop_dirty_or_divergent_baseline"
}

$head = (git rev-parse HEAD).Trim()
if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "semantic-$($head.Substring(0, 12))"
}
$paths = Get-ThresholdSemanticRuntimePaths -RunId $RunId
$legacyTwinPath = "$($paths.LegacyTwinDirectory)/$head.json"
$targetTwinPath = "$($paths.TargetProposalDirectory)/target-twin-$head.json"

& (Join-Path $PSScriptRoot "materialize-legacy-twin.ps1") -OutputPath $legacyTwinPath
& (Join-Path $PSScriptRoot "propose-target-twin.ps1") -LegacyTwinPath $legacyTwinPath -OutputPath $targetTwinPath
& (Join-Path $PSScriptRoot "plan-twin-delta.ps1") -LegacyTwinPath $legacyTwinPath -TargetTwinPath $targetTwinPath -RunId $RunId -PlanOnly
if ($PlanOnly) {
    Assert-ThresholdSemanticEvidenceFileEconomy
    Write-Host "semanticLane.runId=$RunId"
    Write-Host "semanticLane.terminalState=plan_only_ready"
    exit 0
}

throw "stop_authority_missing=semantic workorder execution requires SeniorRefactoringGovernor admission"
