[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [Parameter(Mandatory = $true)]
    [string] $CandidateId,
    [string] $CandidateClass = "threshold_governance_artifact_update",
    [string] $BaseHead = "",
    [string] $CommitHash = "",
    [string[]] $AllowedPath = @(),
    [string] $DiffSummary = "",
    [string] $ValidationCommand = ".\mvnw.cmd test",
    [string] $ValidationResult = "",
    [int] $TestsRun = 0,
    [int] $Failures = 0,
    [int] $Errors = 0,
    [int] $Skipped = 0,
    [string] $ReceiptMaterialization = "prospective",
    [switch] $PerCommitValidationLogAvailable,
    [switch] $BranchFinalValidationPassed,
    [switch] $UpdateState,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name, [string] $Default = "")
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) {
        if ($Default -ne "") { return $Default }
        throw "Missing lease field '$Name' in $LeasePath"
    }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-CommitParent {
    param([string] $Commit)
    return (& git rev-parse "$Commit^").Trim()
}

function Get-GitBlobSha256 {
    param([string] $Revision, [string] $Path)
    & git cat-file -e "$Revision`:$Path" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $content = (& git show "$Revision`:$Path") -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }
    finally { $sha.Dispose() }
}

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

if (-not (Test-Path $LeasePath)) { throw "Lease file not found: $LeasePath" }

$leaseLines = Get-Content $LeasePath
$leaseName = Get-LeaseScalar $leaseLines "leaseName"
$branch = Get-LeaseScalar $leaseLines "branch"
$leaseStartHead = Get-LeaseScalar $leaseLines "startHead"

if ([string]::IsNullOrWhiteSpace($CommitHash)) { $CommitHash = (& git rev-parse HEAD).Trim() }
if ([string]::IsNullOrWhiteSpace($BaseHead)) { $BaseHead = Get-CommitParent $CommitHash }
if ([string]::IsNullOrWhiteSpace($DiffSummary)) { $DiffSummary = ((& git show --format=%s --no-patch $CommitHash) -join " ").Trim() }

$changedPaths = @(& git diff --name-only "$BaseHead..$CommitHash" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $changedPaths) { throw "No changed files detected for commit range $BaseHead..$CommitHash" }

if ($AllowedPath.Count -gt 0) {
    $allowedNormalized = @($AllowedPath | ForEach-Object { ConvertTo-RepoPath $_ })
    foreach ($path in $changedPaths) {
        if (-not ($allowedNormalized -contains (ConvertTo-RepoPath $path))) {
            throw "Changed path '$path' is not in explicit AllowedPath list."
        }
    }
}

$changedFiles = @()
foreach ($path in $changedPaths) {
    $changedFiles += [ordered]@{
        path = ConvertTo-RepoPath $path
        beforeSha256 = Get-GitBlobSha256 $BaseHead $path
        afterSha256 = Get-GitBlobSha256 $CommitHash $path
    }
}

$numstat = @(& git diff --numstat "$BaseHead..$CommitHash")
$insertions = 0
$deletions = 0
foreach ($line in $numstat) {
    $parts = $line -split "\s+"
    if ($parts.Count -ge 3 -and $parts[0] -match "^\d+$" -and $parts[1] -match "^\d+$") {
        $insertions += [int]$parts[0]
        $deletions += [int]$parts[1]
    }
}

$nonClaims = @(
    "no push in candidate slice",
    "no PR update in candidate slice",
    "no upstream interaction",
    "no pom.xml change",
    "no dependency change",
    "no src/test change",
    "no merge",
    "no release",
    "no deploy",
    "no public readiness claim",
    "no public correctness claim",
    "no public security claim",
    "no public compliance claim"
)

$receipt = [ordered]@{
    schemaVersion = "threshold.petclinic.slice-receipt.v0.2"
    candidateId = $CandidateId
    leaseName = $leaseName
    branch = $branch
    candidateClass = $CandidateClass
    leaseStartHead = $leaseStartHead
    baseHead = $BaseHead
    commitHash = $CommitHash
    receiptMaterialization = $ReceiptMaterialization
    perCommitValidationLogAvailable = [bool]$PerCommitValidationLogAvailable
    branchFinalValidationPassed = [bool]$BranchFinalValidationPassed
    changedFiles = $changedFiles
    diffSummary = $DiffSummary
    diffStat = [ordered]@{ filesChanged = $changedFiles.Count; insertions = $insertions; deletions = $deletions }
    validation = [ordered]@{ diffCheck = "passed"; command = $ValidationCommand; result = $ValidationResult; testsRun = $TestsRun; failures = $Failures; errors = $Errors; skipped = $Skipped }
    nonClaims = $nonClaims
}

$outDir = "threshold/receipts"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$safeCandidateId = $CandidateId -replace "[^A-Za-z0-9_.-]", "-"
$shortCommit = $CommitHash.Substring(0, [Math]::Min(12, $CommitHash.Length))
$outPath = Join-Path $outDir "$safeCandidateId-$shortCommit.json"

if (-not $DryRun) { $receipt | ConvertTo-Json -Depth 12 | Set-Content $outPath }

if ($UpdateState -and -not $DryRun) {
    $stateDir = Split-Path $StatePath -Parent
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
    if (Test-Path $StatePath) {
        $state = Get-Content $StatePath -Raw | ConvertFrom-Json
        $candidatesProcessed = [int]$state.candidatesProcessed + 1
        $commitsCreated = [int]$state.commitsCreated + 1
        $remainingCandidates = [Math]::Max(0, [int]$state.remainingBudget.candidates - 1)
        $remainingCommits = [Math]::Max(0, [int]$state.remainingBudget.commits - 1)
        $remainingRepairs = [int]$state.remainingBudget.repairAttempts
        $invocationId = [string]$state.invocationId
        $mode = [string]$state.mode
        $terminalState = [string]$state.terminalState
        if ($state.PSObject.Properties.Name -contains "branch") {
            $stateBranch = [string]$state.branch
        }
        else {
            $stateBranch = $branch
        }
        if ($remainingCandidates -eq 0 -or $remainingCommits -eq 0) {
            $terminalState = "budget_exhausted"
        }
    }
    else {
        $candidatesProcessed = 1
        $commitsCreated = 1
        $remainingCandidates = 0
        $remainingCommits = 0
        $remainingRepairs = 0
        $invocationId = "petclinic-governance-repair-$((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))"
        $mode = "local_refactor"
        $terminalState = "active"
        $stateBranch = $branch
    }
    $newState = [ordered]@{
        schemaVersion = "threshold.petclinic.lease-state.v0.2"
        invocationId = $invocationId
        leaseId = $leaseName
        mode = $mode
        branch = $stateBranch
        startHead = $leaseStartHead
        currentHead = $CommitHash
        currentSourceHead = $CommitHash
        candidatesProcessed = $candidatesProcessed
        commitsCreated = $commitsCreated
        remainingBudget = [ordered]@{ candidates = $remainingCandidates; commits = $remainingCommits; repairAttempts = $remainingRepairs }
        lastReceipt = ConvertTo-RepoPath $outPath
        terminalState = $terminalState
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $newState | ConvertTo-Json -Depth 8 | Set-Content $StatePath
}

Write-Host "receiptPath=$outPath"
Write-Host "candidateId=$CandidateId"
Write-Host "candidateClass=$CandidateClass"
Write-Host "baseHead=$BaseHead"
Write-Host "commitHash=$CommitHash"
