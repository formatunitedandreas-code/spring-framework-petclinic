[CmdletBinding()]
param(
    [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json",
    [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence",
    [int] $MinScore = 70
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

if (-not (Test-Path $CandidatePocketPath)) {
    throw "Candidate pocket not found: $CandidatePocketPath"
}

$pocket = Get-Content -LiteralPath $CandidatePocketPath -Raw | ConvertFrom-Json
$discoverySourceHead = [string](Get-ThresholdJsonProperty $pocket "generatedFromHead" "")
if ([string]::IsNullOrWhiteSpace($discoverySourceHead)) {
    throw "Candidate pocket is missing generatedFromHead."
}

$currentHead = (& git rev-parse HEAD).Trim()
if (-not (Test-ThresholdCommitIsAncestor -Ancestor $discoverySourceHead -Descendant $currentHead)) {
    throw "Candidate discovery source head must be an ancestor of the current evidence head. discoverySourceHead=$discoverySourceHead currentHead=$currentHead"
}

$materializedPaths = New-Object System.Collections.Generic.List[string]
$eligibleCandidates = @(
    $pocket.candidates |
        Where-Object { $_.autoPatchable -eq $true -and [int]$_.score -ge $MinScore }
)

foreach ($candidate in $eligibleCandidates) {
    $candidateId = [string](Get-ThresholdJsonProperty $candidate "candidateId" "")
    if ([string]::IsNullOrWhiteSpace($candidateId)) {
        continue
    }

    $evidence = New-ThresholdCandidateDiscoveryEvidence `
        -BaseHead $discoverySourceHead `
        -CandidateId $candidateId `
        -CandidatePocketPath $CandidatePocketPath `
        -Candidate $candidate
    if ($null -eq $evidence) {
        continue
    }

    $path = Get-ThresholdCandidateDiscoveryEvidencePath `
        -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot `
        -CandidateId $candidateId `
        -BaseHead $discoverySourceHead
    Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $evidence -Path $path
    $materializedPaths.Add((ConvertTo-RepoPath $path))
}

Write-Host "preProductDiscoveryEvidencePrepared=true"
Write-Host "discoverySourceHead=$discoverySourceHead"
Write-Host "evidenceHeadBeforeCommit=$currentHead"
Write-Host "candidateEvidenceCount=$($materializedPaths.Count)"
foreach ($path in $materializedPaths) {
    Write-Host "discoveryEvidencePath=$path"
}
