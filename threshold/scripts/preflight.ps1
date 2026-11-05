[CmdletBinding()]
param(
    [string] $LeasePath = "",
    [switch] $AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/runtime-paths.ps1")
. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")

$runtimePaths = Get-ThresholdRuntimePaths
if ([string]::IsNullOrWhiteSpace($LeasePath)) {
    $LeasePath = $runtimePaths.LeasePath
}

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

$currentBranch = (& git branch --show-current).Trim()
if ($currentBranch -ne $expectedBranch) {
    throw "Branch mismatch. Expected '$expectedBranch', got '$currentBranch'."
}

$currentHead = (& git rev-parse HEAD).Trim()
Assert-ThresholdHeadPolicy -LeaseLines $leaseLines -LeasePath $LeasePath -CurrentHead $currentHead -CurrentBranch $currentBranch

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

Assert-ThresholdChangedPathsAllowed -LeaseLines $leaseLines -ChangedPaths $changedPaths

Write-Host "Threshold preflight passed"
Write-Host "branch=$currentBranch"
Write-Host "head=$currentHead"
Write-Host "changedPaths=$($changedPaths.Count)"
