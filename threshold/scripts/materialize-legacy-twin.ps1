[CmdletBinding()]
param(
    [string] $OutputPath = "",
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")
$adapterRoot = Join-Path $PSScriptRoot "..\adapters\petclinic-semantic-twin"
Import-Module (Join-Path $adapterRoot "java-structure-extractor.psm1") -Force
Import-Module (Join-Path $adapterRoot "spring-binding-extractor.psm1") -Force
Import-Module (Join-Path $adapterRoot "persistence-profile-extractor.psm1") -Force
Import-Module (Join-Path $adapterRoot "test-behavior-extractor.psm1") -Force
Import-Module (Join-Path $adapterRoot "query-observation-adapter.psm1") -Force

$head = (git rev-parse HEAD).Trim()
$paths = Get-ThresholdSemanticRuntimePaths
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$($paths.LegacyTwinDirectory)/$head.json"
}

$javaEvidence = Get-PetClinicJavaStructureEvidence
$springEvidence = Get-PetClinicSpringBindingEvidence
$profileEvidence = Get-PetClinicPersistenceProfileEvidence
$testEvidence = Get-PetClinicTestBehaviorEvidence
$queryEvidence = Get-PetClinicQueryObservationEvidence

$snapshot = [ordered]@{
    schemaVersion = "threshold.semantic-twin.v0.1"
    twinId = "petclinic-legacy:$head"
    twinDigest = ""
    repositoryRef = "spring-framework-petclinic"
    sourceHead = $head
    extractorVersion = "petclinic-semantic-twin-adapter.v0.1"
    capabilityKgDigest = "not_materialized"
    fidelityKgDigest = "not_materialized"
    capabilities = @(@{ id = "capability:petclinic.application"; evidenceRefs = @("source:pom.xml") })
    implementationNodes = @($javaEvidence.classes)
    behaviorInvariants = @($testEvidence.tests | ForEach-Object { @{ id = "behavior:$($_.path)"; evidenceRef = $_.evidenceRef } })
    dependencyEdges = @()
    profileBindings = @($profileEvidence.profiles)
    evidenceClaims = @(
        @{ claimId = "claim:java-structure"; proposition = "java source structure is materialized"; evidence = @($javaEvidence.classes); confidence = 90; classification = "supported"; reasonCodes = @("source_structure_extracted") },
        @{ claimId = "claim:spring-bindings"; proposition = "spring bindings are materialized"; evidence = @($springEvidence.bindings); confidence = 80; classification = "supported"; reasonCodes = @("spring_binding_scan") },
        @{ claimId = "claim:test-behavior"; proposition = "test behavior evidence is materialized"; evidence = @($testEvidence.tests); confidence = 80; classification = "supported"; reasonCodes = @("test_evidence_scan") },
        @{ claimId = "claim:query-observations"; proposition = "query observations are not materialized during plan-only twin extraction"; evidence = @($queryEvidence); confidence = 0; classification = "hypothesis_only"; reasonCodes = @("runtime_query_observation_deferred") }
    )
    unresolvedConflicts = @()
    status = "triangulated"
}

$digestInput = [ordered]@{}
foreach ($key in $snapshot.Keys) {
    if ($key -ne "twinDigest") {
        $digestInput[$key] = $snapshot[$key]
    }
}
$snapshot.twinDigest = Get-ThresholdSha256 -Value (ConvertTo-CanonicalJson -Value $digestInput)

if ($PlanOnly) {
    Write-Host "legacyTwin.planOnly=true"
    Write-Host "legacyTwin.sourceHead=$head"
    Write-Host "legacyTwin.digest=$($snapshot.twinDigest)"
    Write-Host "legacyTwin.outputPath=$OutputPath"
    exit 0
}

Write-ThresholdJsonFile -Path $OutputPath -Value $snapshot
Write-Host "legacyTwin.path=$OutputPath"
Write-Host "legacyTwin.digest=$($snapshot.twinDigest)"
