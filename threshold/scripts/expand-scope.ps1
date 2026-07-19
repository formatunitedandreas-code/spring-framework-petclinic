[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $Reason = "auto_patchable_candidate_shortage"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name' in $LeasePath" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Set-OrAppendLeaseScalar {
    param(
        [System.Collections.Generic.List[string]] $Lines,
        [string] $Name,
        [string] $Value
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*$([regex]::Escape($Name)):\s*.+?$") {
            $Lines[$i] = "${Name}: $Value"
            return
        }
    }

    $insertIndex = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*budget:\s*$") {
            $insertIndex = $i
            break
        }
    }

    $Lines.Insert($insertIndex, "${Name}: $Value")
}

if (-not (Test-Path $LeasePath)) { throw "Lease file not found: $LeasePath" }
if (-not (Test-Path $StatePath)) { throw "Lease state file not found: $StatePath" }
if (-not (Test-Path $GatePath)) { throw "Gate file not found: $GatePath" }

$leaseLines = [System.Collections.Generic.List[string]]::new()
foreach ($line in (Get-Content $LeasePath)) {
    $leaseLines.Add([string]$line)
}

$currentTier = [int](Get-LeaseScalar -Lines $leaseLines -Name "scopeExpansionTier")
$gate = Get-Content $GatePath -Raw | ConvertFrom-Json
if (-not $gate.scopeExpansionPolicy -or $gate.scopeExpansionPolicy.enabled -ne $true) {
    throw "Scope expansion policy is not enabled in $GatePath."
}

$tiers = @($gate.scopeExpansionPolicy.tiers | Sort-Object { [int]$_.tier })
$nextTier = $tiers | Where-Object { [int]$_.tier -gt $currentTier } | Select-Object -First 1

if (-not $nextTier) {
    Write-Host "scopeExpansionApplied=false"
    Write-Host "scopeExpansionExhausted=true"
    Write-Host "currentTier=$currentTier"
    exit 0
}

Set-OrAppendLeaseScalar -Lines $leaseLines -Name "scopeExpansionTier" -Value ([string]$nextTier.tier)
Set-OrAppendLeaseScalar -Lines $leaseLines -Name "longLineThreshold" -Value ([string]$nextTier.thresholds.longLineThreshold)
Set-OrAppendLeaseScalar -Lines $leaseLines -Name "commentWrapThreshold" -Value ([string]$nextTier.thresholds.commentWrapThreshold)
Set-OrAppendLeaseScalar -Lines $leaseLines -Name "springDataQueryThreshold" -Value ([string]$nextTier.thresholds.springDataQueryThreshold)
Set-OrAppendLeaseScalar -Lines $leaseLines -Name "repositoryMethodLengthThreshold" -Value ([string]$nextTier.thresholds.repositoryMethodLengthThreshold)
Set-OrAppendLeaseScalar -Lines $leaseLines -Name "utilityMethodLengthThreshold" -Value ([string]$nextTier.thresholds.utilityMethodLengthThreshold)
if ($nextTier.PSObject.Properties["minScore"]) {
    Set-OrAppendLeaseScalar -Lines $leaseLines -Name "minScore" -Value ([string]$nextTier.minScore)
}

$leaseLines | Set-Content $LeasePath

$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if (-not $state.PSObject.Properties["scopeExpansionTier"]) {
    $state | Add-Member -NotePropertyName "scopeExpansionTier" -NotePropertyValue ([int]$nextTier.tier)
}
else {
    $state.scopeExpansionTier = [int]$nextTier.tier
}
if (-not $state.PSObject.Properties["scopeExpansionReason"]) {
    $state | Add-Member -NotePropertyName "scopeExpansionReason" -NotePropertyValue $Reason
}
else {
    $state.scopeExpansionReason = $Reason
}
if (-not $state.PSObject.Properties["scopeExpansionAppliedAt"]) {
    $state | Add-Member -NotePropertyName "scopeExpansionAppliedAt" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o"))
}
else {
    $state.scopeExpansionAppliedAt = (Get-Date).ToUniversalTime().ToString("o")
}
if ($nextTier.PSObject.Properties["minScore"]) {
    if (-not $state.PSObject.Properties["minScore"]) {
        $state | Add-Member -NotePropertyName "minScore" -NotePropertyValue ([int]$nextTier.minScore)
    }
    else {
        $state.minScore = [int]$nextTier.minScore
    }
}
$state.terminalState = "active"
$state.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
$state | ConvertTo-Json -Depth 10 | Set-Content $StatePath

Write-Host "scopeExpansionApplied=true"
Write-Host "previousTier=$currentTier"
Write-Host "nextTier=$($nextTier.tier)"
Write-Host "tierName=$($nextTier.name)"
if ($nextTier.PSObject.Properties["minScore"]) {
    Write-Host "minScore=$($nextTier.minScore)"
}
Write-Host "reason=$Reason"
