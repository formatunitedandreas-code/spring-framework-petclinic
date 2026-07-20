[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $WorkorderPath,

    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$adapterRoot = Join-Path $PSScriptRoot "..\adapters\petclinic-semantic-twin"
Import-Module (Join-Path $adapterRoot "refactoring-executor.psm1") -Force

$workorder = Get-Content $WorkorderPath -Raw | ConvertFrom-Json
if (-not $workorder.workorderId -or ([string]$workorder.workorderId -notlike "semantic-workorder:*")) {
    throw "semantic_workorder_required"
}
if (-not $workorder.admissionDecision -or $workorder.admissionDecision -notlike "admit_*") {
    throw "stop_authority_missing"
}

$result = Invoke-PetClinicSemanticRefactoringExecutor -Workorder $workorder -PlanOnly:$PlanOnly
Write-Host "semanticWorkorder.execution=$($result.execution)"
