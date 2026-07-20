[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $LegacyTwinPath,

    [Parameter(Mandatory = $true)]
    [string] $TargetTwinPath,

    [string] $RunId = "",
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

$legacyTwin = Get-Content $LegacyTwinPath -Raw | ConvertFrom-Json
$targetTwin = Get-Content $TargetTwinPath -Raw | ConvertFrom-Json
if ($targetTwin.legacyTwinDigest -ne $legacyTwin.twinDigest) {
    throw "stop_source_head_mismatch=target legacyTwinDigest does not match legacy twin"
}
if ($targetTwin.authorityFlags.execute -ne $false -or $targetTwin.authorityFlags.commit -ne $false -or $targetTwin.authorityFlags.push -ne $false -or $targetTwin.authorityFlags.merge -ne $false) {
    throw "target_authority_flags_must_be_false"
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "semantic-$($legacyTwin.sourceHead.Substring(0, 12))"
}
$paths = Get-ThresholdSemanticRuntimePaths -RunId $RunId
$legacyCapabilities = @($legacyTwin.capabilities | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$preservedCapabilities = @($targetTwin.preservedCapabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$legacyBehaviors = @($legacyTwin.behaviorInvariants | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$preservedBehaviors = @($targetTwin.preservedBehaviorInvariants | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$unresolvedConflicts = @($legacyTwin.unresolvedConflicts)
$findings = New-Object System.Collections.Generic.List[object]

$missingCapabilities = @($legacyCapabilities | Where-Object { $preservedCapabilities -notcontains $_ })
foreach ($missing in $missingCapabilities) {
    $findings.Add([pscustomobject]@{ code = "target_loses_capability"; ref = $missing })
}

$missingBehaviors = @($legacyBehaviors | Where-Object { $preservedBehaviors -notcontains $_ })
foreach ($missing in $missingBehaviors) {
    $findings.Add([pscustomobject]@{ code = "target_loses_behavior_invariant"; ref = $missing })
}

foreach ($conflict in $unresolvedConflicts) {
    $findings.Add([pscustomobject]@{ code = "unresolved_semantic_conflict"; ref = $conflict })
}

$capabilityPreservationPassed = $missingCapabilities.Count -eq 0
$behaviorPreservationPassed = $missingBehaviors.Count -eq 0
$evidenceSufficiencyPassed = $unresolvedConflicts.Count -eq 0 -and $legacyTwin.status -in @("triangulated", "verified")
$transitionFeasibilityPassed = $targetTwin.transformations.Count -eq 0
$guardianResult = if ($capabilityPreservationPassed -and $behaviorPreservationPassed -and $evidenceSufficiencyPassed -and $transitionFeasibilityPassed) {
    "target_admissible_for_delta_planning"
}
elseif (-not $evidenceSufficiencyPassed) {
    "target_requires_more_evidence"
}
else {
    "target_rejected"
}

$delta = [ordered]@{
    deltaId = "twin-delta:$RunId"
    legacyTwinDigest = $legacyTwin.twinDigest
    targetTwinDigest = Get-ThresholdSha256 -Value (ConvertTo-CanonicalJson -Value $targetTwin)
    preserve = @($targetTwin.preservedCapabilities)
    introduce = @()
    redirect = @()
    deprecate = @()
    predictedFiles = @()
    predictedTests = @()
    predictedProfiles = @($legacyTwin.profileBindings | ForEach-Object { $_.profile })
    transformationGraph = @()
    rollbackPlan = @()
    expectedMetrics = @($targetTwin.objectives)
    estimatedDeliveryCost = @{ logicalCommits = 0; changedFiles = 0; evidenceFiles = 3 }
}

$guardian = [ordered]@{
    proposalId = $targetTwin.proposalId
    legacyTwinDigest = $legacyTwin.twinDigest
    capabilityPreservationPassed = $capabilityPreservationPassed
    behaviorPreservationPassed = $behaviorPreservationPassed
    dependencyPolicyPassed = $true
    evidenceSufficiencyPassed = $evidenceSufficiencyPassed
    transitionFeasibilityPassed = $transitionFeasibilityPassed
    findings = @($findings.ToArray())
    result = $guardianResult
}

if ($guardian.result -ne "target_admissible_for_delta_planning") {
    throw "semantic_guardian_blocked=$($guardian.result)"
}

if ($PlanOnly) {
    Write-Host "twinDelta.planOnly=true"
    Write-Host "twinDelta.deltaId=$($delta.deltaId)"
    Write-Host "semanticGuardian.result=$($guardian.result)"
    Write-Host "twinDelta.outputPath=$($paths.TwinDeltaPath)"
    exit 0
}

Write-ThresholdJsonFile -Path $paths.TwinDeltaPath -Value $delta
Write-ThresholdJsonFile -Path $paths.EvidenceDigestsPath -Value @{
    runId = $RunId
    legacyTwinDigest = $legacyTwin.twinDigest
    targetTwinDigest = $delta.targetTwinDigest
    semanticGuardianDigest = Get-ThresholdSha256 -Value (ConvertTo-CanonicalJson -Value $guardian)
    sourceHead = $legacyTwin.sourceHead
}
Write-Host "twinDelta.path=$($paths.TwinDeltaPath)"
Write-Host "evidenceDigests.path=$($paths.EvidenceDigestsPath)"
