[CmdletBinding()]
param(
    [string] $PrBaseHead = "",
    [string] $BaseRef = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kgScript = Join-Path $PSScriptRoot "materialize-knowledge-graphs.ps1"
if (-not [string]::IsNullOrWhiteSpace($PrBaseHead) -and -not [string]::IsNullOrWhiteSpace($BaseRef)) {
    & $kgScript -CheckOnly -PrBaseHead $PrBaseHead -BaseRef $BaseRef
}
elseif (-not [string]::IsNullOrWhiteSpace($PrBaseHead)) {
    & $kgScript -CheckOnly -PrBaseHead $PrBaseHead
}
elseif (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
    & $kgScript -CheckOnly -BaseRef $BaseRef
}
else {
    & $kgScript -CheckOnly
}

& (Join-Path $PSScriptRoot "verify-receipt-chain.ps1") -CheckOnly

$training = Get-Content "threshold/trainer/training-report.json" -Raw | ConvertFrom-Json
$heldAutoPatchable = @($training.decisions | Where-Object { $_.decision -eq "held" -and $_.fidelityLevel -notin @("F0_UNOBSERVED", "F1_REVIEW_REQUIRED") })
if ($heldAutoPatchable.Count -gt 0) {
    throw "trainer_decision_inconsistent=$($heldAutoPatchable[0].candidateClass)"
}

Write-Host "kgGovernance=passed"
