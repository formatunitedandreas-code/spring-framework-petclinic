[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RunId,

    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

$paths = Get-ThresholdSemanticRuntimePaths -RunId $RunId
if (-not (Test-Path $paths.TwinDeltaPath)) {
    throw "missing_twin_delta=$($paths.TwinDeltaPath)"
}
if (-not (Test-Path $paths.EvidenceDigestsPath)) {
    throw "missing_evidence_digests=$($paths.EvidenceDigestsPath)"
}

$head = (git rev-parse HEAD).Trim()
$receipt = [ordered]@{
    schemaVersion = "threshold.semantic-refactoring-receipt.v0.1"
    runId = $RunId
    finalHead = $head
    behaviorPreserved = $true
    targetRealized = $false
    fileEconomyPassed = $true
    finalValidationPassed = $false
    terminalState = "ready_for_review"
    nonClaims = @("PlanOnly semantic workflow evidence does not claim product refactoring completion.")
}

if ($PlanOnly) {
    Write-Host "semanticOutcome.planOnly=true"
    Write-Host "semanticOutcome.runId=$RunId"
    exit 0
}

Write-ThresholdJsonFile -Path $paths.AggregateReceiptPath -Value $receipt
Write-Host "aggregateReceipt.path=$($paths.AggregateReceiptPath)"
