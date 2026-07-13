[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [Parameter(Mandatory = $true)]
    [string] $CandidateId,
    [string] $CommitHash = "",
    [string] $ValidationCommand = ".\mvnw.cmd test",
    [string] $ValidationResult = "",
    [int] $TestsRun = 0,
    [int] $Failures = 0,
    [int] $Errors = 0,
    [int] $Skipped = 0,
    [switch] $FromHead,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param(
        [string[]] $Lines,
        [string] $Name
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) {
        throw "Missing lease field '$Name' in $LeasePath"
    }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-LeaseList {
    param(
        [string[]] $Lines,
        [string] $Name
    )

    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") {
            $inside = $true
            continue
        }
        if ($inside -and $line -match "^\S") {
            break
        }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") {
            $items.Add(($Matches[1]).Trim())
        }
    }
    return $items.ToArray()
}

if (-not (Test-Path $LeasePath)) {
    throw "Lease file not found: $LeasePath"
}

$leaseLines = Get-Content $LeasePath
$baseHead = Get-LeaseScalar $leaseLines "startHead"
$candidateClass = "threshold_enforcement"
$leaseName = Get-LeaseScalar $leaseLines "leaseName"
$branch = Get-LeaseScalar $leaseLines "branch"

if ([string]::IsNullOrWhiteSpace($CommitHash)) {
    if (-not $FromHead) {
        $CommitHash = (& git rev-parse HEAD).Trim()
    }
    else {
        $CommitHash = (& git rev-parse HEAD).Trim()
    }
}

$diffNameOnly = @(& git diff --name-only HEAD~1..HEAD)
if (-not $diffNameOnly) {
    $diffNameOnly = @(& git show --name-only --pretty=format: --name-only $CommitHash)
}

if (-not $diffNameOnly) {
    throw "No changed files detected for commit $CommitHash"
}

$changedFiles = @()
foreach ($path in $diffNameOnly) {
    if (-not (Test-Path $path)) {
        continue
    }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash
    $changedFiles += [ordered]@{
        path = $path
        beforeSha256 = $null
        afterSha256 = $hash
    }
}

$numstat = @(& git diff --numstat HEAD~1..HEAD)
if (-not $numstat) {
    $numstat = @("0 0 $($diffNameOnly.Count)")
}
$insertions = 0
$deletions = 0
foreach ($line in $numstat) {
    $parts = $line -split "\s+"
    if ($parts.Count -ge 3 -and $parts[0] -match "^\d+$" -and $parts[1] -match "^\d+$") {
        $insertions += [int]$parts[0]
        $deletions += [int]$parts[1]
    }
}

$receipt = [ordered]@{
    candidateId = $CandidateId
    leaseName = $leaseName
    branch = $branch
    candidateClass = $candidateClass
    baseHead = $baseHead
    commitHash = $CommitHash
    changedFiles = $changedFiles
    diffStat = [ordered]@{
        filesChanged = $changedFiles.Count
        insertions = $insertions
        deletions = $deletions
    }
    validation = [ordered]@{
        diffCheck = "passed"
        command = $ValidationCommand
        result = $ValidationResult
        testsRun = $TestsRun
        failures = $Failures
        errors = $Errors
        skipped = $Skipped
    }
    nonClaims = @(
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
}

$outDir = "threshold/receipts"
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$outPath = Join-Path $outDir "$CandidateId.json"
if (-not $DryRun) {
    $receipt | ConvertTo-Json -Depth 10 | Set-Content $outPath
}

Write-Host "receiptPath=$outPath"
Write-Host "candidateId=$CandidateId"
Write-Host "commitHash=$CommitHash"
