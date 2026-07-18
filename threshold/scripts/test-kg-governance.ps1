[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/materialize-knowledge-graphs.ps1" -CheckOnly
if ($LASTEXITCODE -ne 0) { throw "kg_materialization_check_failed" }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/verify-receipt-chain.ps1" -CheckOnly
if ($LASTEXITCODE -ne 0) { throw "receipt_chain_check_failed" }

$training = Get-Content "threshold/trainer/training-report.json" -Raw | ConvertFrom-Json
$heldAutoPatchable = @($training.decisions | Where-Object { $_.decision -eq "held" -and $_.fidelityLevel -notin @("F0_UNOBSERVED", "F1_REVIEW_REQUIRED") })
if ($heldAutoPatchable.Count -gt 0) {
    throw "trainer_decision_inconsistent=$($heldAutoPatchable[0].candidateClass)"
}

Write-Host "kgGovernance=passed"
