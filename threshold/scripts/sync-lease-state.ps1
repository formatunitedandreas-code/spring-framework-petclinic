[CmdletBinding(DefaultParameterSetName = "Check")]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [Parameter(ParameterSetName = "Check")]
    [switch] $CheckOnly,
    [Parameter(ParameterSetName = "Write")]
    [switch] $Write
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name' in $LeasePath" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-LeaseBudgetValue {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing budget field '$Name' in $LeasePath" }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "")
}

if (-not (Test-Path $LeasePath)) { throw "Lease file not found: $LeasePath" }
if (-not (Test-Path $StatePath)) { throw "Lease state file not found: $StatePath" }

$leaseLines = Get-Content $LeasePath
$state = Get-Content $StatePath -Raw | ConvertFrom-Json

$leaseName = Get-LeaseScalar $leaseLines "leaseName"
$expectedBranch = Get-LeaseScalar $leaseLines "branch"
$startHead = Get-LeaseScalar $leaseLines "startHead"
$headPolicy = Get-LeaseScalar $leaseLines "headPolicy"
$maxCandidates = Get-LeaseBudgetValue $leaseLines "maxCandidatesThisRun"
$maxCommits = Get-LeaseBudgetValue $leaseLines "maxCommitsThisRun"
$maxRepairs = Get-LeaseBudgetValue $leaseLines "maxRepairAttemptsPerCandidate"

$currentBranch = (& git branch --show-current).Trim()
$currentHead = (& git rev-parse HEAD).Trim()

if ($currentBranch -ne $expectedBranch) {
    throw "Branch mismatch. expected=$expectedBranch actual=$currentBranch"
}

if ($headPolicy -eq "exactStartHead" -and $currentHead -ne $startHead) {
    throw "HEAD mismatch. expected=$startHead actual=$currentHead"
}

if ($headPolicy -eq "descendantOfStartHead") {
    & git merge-base --is-ancestor $startHead HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "HEAD '$currentHead' is not a descendant of lease startHead '$startHead'."
    }
}

if ($state.leaseId -ne $leaseName) {
    throw "State leaseId mismatch. expected=$leaseName actual=$($state.leaseId)"
}

if ($state.branch -ne $expectedBranch) {
    throw "State branch mismatch. expected=$expectedBranch actual=$($state.branch)"
}

$remainingCandidates = [int]$state.remainingBudget.candidates
$remainingCommits = [int]$state.remainingBudget.commits
$remainingRepairs = [int]$state.remainingBudget.repairAttempts
if ($remainingCandidates -lt 0 -or $remainingCandidates -gt $maxCandidates) {
    throw "State candidate budget is outside lease bounds. remaining=$remainingCandidates max=$maxCandidates"
}
if ($remainingCommits -lt 0 -or $remainingCommits -gt $maxCommits) {
    throw "State commit budget is outside lease bounds. remaining=$remainingCommits max=$maxCommits"
}
if ($remainingRepairs -lt 0 -or $remainingRepairs -gt $maxRepairs) {
    throw "State repair budget is outside lease bounds. remaining=$remainingRepairs max=$maxRepairs"
}

if ($Write.IsPresent) {
    $state.branch = $currentBranch
    $state.currentHead = $currentHead
    $state.currentSourceHead = $currentHead
    if (-not $state.PSObject.Properties["runtimeObservedHead"]) {
        $state | Add-Member -NotePropertyName "runtimeObservedHead" -NotePropertyValue $currentHead
    } else {
        $state.runtimeObservedHead = $currentHead
    }
    if (-not $state.PSObject.Properties["runtimeObservedAt"]) {
        $state | Add-Member -NotePropertyName "runtimeObservedAt" -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o")
    } else {
        $state.runtimeObservedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $StatePath
}

Write-Host "Threshold lease-state sync passed"
Write-Host "mode=$(if ($Write.IsPresent) { 'write' } else { 'check' })"
Write-Host "branch=$currentBranch"
Write-Host "head=$currentHead"
Write-Host "stateCurrentHead=$($state.currentHead)"
Write-Host "stateCurrentSourceHead=$($state.currentSourceHead)"
Write-Host "remainingCandidates=$remainingCandidates"
Write-Host "remainingCommits=$remainingCommits"
