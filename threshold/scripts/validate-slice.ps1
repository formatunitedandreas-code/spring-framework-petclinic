[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [switch] $SkipMavenTest
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

function Get-BudgetValue {
    param(
        [string[]] $Lines,
        [string] $Name
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) {
        throw "Missing budget field '$Name' in $LeasePath"
    }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "")
}

if (-not (Test-Path $LeasePath)) {
    throw "Lease file not found: $LeasePath"
}

$leaseLines = Get-Content $LeasePath
$allowedPaths = Get-LeaseList $leaseLines "allowedPaths"
$forbiddenPaths = Get-LeaseList $leaseLines "forbiddenPaths"
$maxFiles = Get-BudgetValue $leaseLines "maxFilesPerCandidate"
$maxGovernanceFiles = Get-BudgetValue $leaseLines "maxGovernanceFilesPerCandidate"
$maxChangedLines = Get-BudgetValue $leaseLines "maxChangedLinesPerCandidate"
$maxGovernanceChangedLines = Get-BudgetValue $leaseLines "maxGovernanceChangedLinesPerCandidate"
$javaHome = Get-LeaseScalar $leaseLines "javaHome"

$changedPaths = @(& git diff --name-only)
if (-not $changedPaths) {
    $changedPaths = @(& git diff --cached --name-only)
}
$untrackedPaths = @(& git ls-files --others --exclude-standard)
if ($untrackedPaths) {
    $changedPaths = @($changedPaths + $untrackedPaths | Select-Object -Unique)
}
if (-not $changedPaths) {
    throw "No slice changes found in working tree or index."
}
$governancePaths = @($changedPaths | Where-Object {
        ($_ -replace "\\", "/") -like "threshold/*" -or
        ($_ -replace "\\", "/") -eq ".github/workflows/threshold-governance.yml"
    })
$fileBudget = $maxFiles
if ($governancePaths.Count -eq $changedPaths.Count) {
    $fileBudget = $maxGovernanceFiles
}
if ($changedPaths.Count -gt $fileBudget) {
    throw "Slice changes $($changedPaths.Count) files, exceeding file budget=$fileBudget."
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

$changedLineCount = 0
$numstat = & git diff --numstat
if (-not $numstat) {
    $numstat = & git diff --cached --numstat
}
foreach ($line in $numstat) {
    $parts = $line -split "\s+"
    if ($parts.Count -ge 2 -and $parts[0] -match "^\d+$" -and $parts[1] -match "^\d+$") {
        $changedLineCount += [int]$parts[0] + [int]$parts[1]
    }
}
foreach ($path in $untrackedPaths) {
    if (Test-Path $path) {
        $changedLineCount += (Get-Content $path).Count
    }
}
$changedLineBudget = $maxChangedLines
if ($governancePaths.Count -eq $changedPaths.Count) {
    $changedLineBudget = $maxGovernanceChangedLines
}
if ($changedLineCount -gt $changedLineBudget) {
    throw "Slice changes $changedLineCount lines, exceeding changed-line budget=$changedLineBudget."
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed."
}

if (-not $SkipMavenTest) {
    $env:JAVA_HOME = $javaHome
    if (Test-Path ".\mvnw.cmd") {
        & .\mvnw.cmd test
    }
    else {
        & ./mvnw test
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Maven test failed."
    }
}

Write-Host "Threshold slice validation passed"
Write-Host "changedPaths=$($changedPaths.Count)"
Write-Host "changedLines=$changedLineCount"
Write-Host "mavenTestSkipped=$($SkipMavenTest.IsPresent)"
