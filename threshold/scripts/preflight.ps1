[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [switch] $AllowDirty
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

function Test-PathAgainstPattern {
    param(
        [string] $Path,
        [string] $Pattern
    )

    $normalizedPath = $Path -replace "\\", "/"
    $normalizedPattern = $Pattern -replace "\\", "/"
    return [System.Management.Automation.WildcardPattern]::new($normalizedPattern, "IgnoreCase").IsMatch($normalizedPath)
}

if (-not (Test-Path $LeasePath)) {
    throw "Lease file not found: $LeasePath"
}

$leaseLines = Get-Content $LeasePath
$expectedBranch = Get-LeaseScalar $leaseLines "branch"
$startHead = Get-LeaseScalar $leaseLines "startHead"
$headPolicy = Get-LeaseScalar $leaseLines "headPolicy"
$allowedPaths = Get-LeaseList $leaseLines "allowedPaths"
$forbiddenPaths = Get-LeaseList $leaseLines "forbiddenPaths"

$currentBranch = (& git branch --show-current).Trim()
if ($currentBranch -ne $expectedBranch) {
    throw "Branch mismatch. Expected '$expectedBranch', got '$currentBranch'."
}

$currentHead = (& git rev-parse HEAD).Trim()
if ($headPolicy -eq "exactStartHead" -and $currentHead -ne $startHead) {
    throw "HEAD mismatch. Expected '$startHead', got '$currentHead'."
}
if ($headPolicy -eq "descendantOfStartHead") {
    & git merge-base --is-ancestor $startHead HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "HEAD '$currentHead' is not a descendant of lease startHead '$startHead'."
    }
}

$statusLines = & git status --porcelain
if (-not $AllowDirty -and $statusLines) {
    throw "Worktree is not clean. Commit, stash, or revert local changes before preflight."
}

$changedPaths = @(& git diff --name-only)
if (-not $changedPaths) {
    $changedPaths = @(& git diff --cached --name-only)
}
$untrackedPaths = @(& git ls-files --others --exclude-standard)
if ($untrackedPaths) {
    $changedPaths = @($changedPaths + $untrackedPaths | Select-Object -Unique)
}

foreach ($path in $changedPaths) {
    $isAllowed = $false
    foreach ($pattern in $allowedPaths) {
        if (Test-PathAgainstPattern $path $pattern) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed) {
        throw "Changed path is outside lease allowlist: $path"
    }

    foreach ($pattern in $forbiddenPaths) {
        if (Test-PathAgainstPattern $path $pattern) {
            throw "Changed path is forbidden by lease: $path"
        }
    }
}

Write-Host "Threshold preflight passed"
Write-Host "branch=$currentBranch"
Write-Host "head=$currentHead"
Write-Host "changedPaths=$($changedPaths.Count)"
