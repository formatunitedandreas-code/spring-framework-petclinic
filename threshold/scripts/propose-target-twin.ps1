[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $LegacyTwinPath,

    [string] $OutputPath = "",
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")
$adapterRoot = Join-Path $PSScriptRoot "..\adapters\petclinic-semantic-twin"
Import-Module (Join-Path $adapterRoot "target-mapping-adapter.psm1") -Force

$legacyTwin = Get-Content $LegacyTwinPath -Raw | ConvertFrom-Json
$proposal = New-PetClinicTargetMappingProposal -LegacyTwin $legacyTwin
$paths = Get-ThresholdSemanticRuntimePaths
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$($paths.TargetProposalDirectory)/$($proposal.proposalId -replace ':','-').json"
}

if ($PlanOnly) {
    Write-Host "targetTwin.planOnly=true"
    Write-Host "targetTwin.legacyTwinDigest=$($proposal.legacyTwinDigest)"
    Write-Host "targetTwin.outputPath=$OutputPath"
    exit 0
}

Write-ThresholdJsonFile -Path $OutputPath -Value $proposal
Write-Host "targetTwin.path=$OutputPath"
