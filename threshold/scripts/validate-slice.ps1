[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [switch] $SkipMavenTest,
    [switch] $RequireHeadReceipt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name' in $LeasePath" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-LeaseList {
    param([string[]] $Lines, [string] $Name)
    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") { $inside = $true; continue }
        if ($inside -and $line -match "^\S") { break }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") { $items.Add(($Matches[1]).Trim()) }
    }
    return $items.ToArray()
}

function Test-PathAgainstPattern {
    param([string] $Path, [string] $Pattern)
    $normalizedPath = $Path -replace "\\", "/"
    $normalizedPattern = $Pattern -replace "\\", "/"
    return [System.Management.Automation.WildcardPattern]::new($normalizedPattern, "IgnoreCase").IsMatch($normalizedPath)
}

function Get-BudgetValue {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing budget field '$Name' in $LeasePath" }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "")
}

function Test-GovernancePath {
    param([string] $Path)
    $normalized = $Path -replace "\\", "/"
    return $normalized -like "threshold/*" -or $normalized -eq ".github/workflows/threshold-governance.yml"
}

function Get-ReceiptForCommit {
    param([string] $CommitHash)
    $receiptPaths = @(Get-ChildItem threshold/receipts -Filter *.json -ErrorAction SilentlyContinue)
    foreach ($receiptPath in $receiptPaths) {
        $receipt = Get-Content $receiptPath.FullName -Raw | ConvertFrom-Json
        if ($receipt.commitHash -eq $CommitHash) { return $receiptPath.FullName }
    }
    return $null
}

if (-not (Test-Path $LeasePath)) { throw "Lease file not found: $LeasePath" }

$leaseLines = Get-Content $LeasePath
$allowedPaths = Get-LeaseList $leaseLines "allowedPaths"
$forbiddenPaths = Get-LeaseList $leaseLines "forbiddenPaths"
$maxFiles = Get-BudgetValue $leaseLines "maxFilesPerCandidate"
$maxGovernanceFiles = Get-BudgetValue $leaseLines "maxGovernanceFilesPerCandidate"
$maxChangedLines = Get-BudgetValue $leaseLines "maxChangedLinesPerCandidate"
$maxGovernanceChangedLines = Get-BudgetValue $leaseLines "maxGovernanceChangedLinesPerCandidate"
$javaHome = Get-LeaseScalar $leaseLines "javaHome"
$expectedBranch = Get-LeaseScalar $leaseLines "branch"
$leaseStartHead = Get-LeaseScalar $leaseLines "startHead"

$currentBranch = (& git branch --show-current).Trim()
if ($currentBranch -ne $expectedBranch) { throw "Branch mismatch. expected=$expectedBranch actual=$currentBranch" }

if (Test-Path $StatePath) {
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    if ([int]$state.remainingBudget.candidates -lt 0 -or [int]$state.remainingBudget.commits -lt 0) {
        throw "Lease state budget is negative: $StatePath"
    }
}

$changedPaths = @(& git diff --name-only)
if (-not $changedPaths) { $changedPaths = @(& git diff --cached --name-only) }
$untrackedPaths = @(& git ls-files --others --exclude-standard)
if ($untrackedPaths) { $changedPaths = @($changedPaths + $untrackedPaths | Select-Object -Unique) }

if (-not $changedPaths) {
    if ($RequireHeadReceipt) {
        $head = (& git rev-parse HEAD).Trim()
        $receipt = Get-ReceiptForCommit $head
        if (-not $receipt) {
            $headPaths = @(& git diff-tree --no-commit-id --name-only -r $head)
            $headIsGovernanceOnly = $headPaths.Count -gt 0
            foreach ($path in $headPaths) {
                if (-not (Test-GovernancePath $path)) {
                    $headIsGovernanceOnly = $false
                    break
                }
            }
            if (-not $headIsGovernanceOnly) {
                throw "No working tree changes and no receipt for HEAD $head."
            }

            $latestSourceCommit = $null
            $commits = @(& git rev-list --reverse "$leaseStartHead..HEAD")
            foreach ($commit in $commits) {
                $commitPaths = @(& git diff-tree --no-commit-id --name-only -r $commit)
                if ($commitPaths.Count -eq 0) { continue }
                $governanceOnly = $true
                foreach ($path in $commitPaths) {
                    if (-not (Test-GovernancePath $path)) {
                        $governanceOnly = $false
                        break
                    }
                }
                if (-not $governanceOnly) {
                    $latestSourceCommit = $commit
                }
            }
            if (-not $latestSourceCommit) {
                throw "No source commit detected after lease startHead $leaseStartHead."
            }

            $receipt = Get-ReceiptForCommit $latestSourceCommit
            if (-not $receipt) {
                throw "Latest source commit $latestSourceCommit has no receipt."
            }
        }
        Write-Host "Threshold slice validation passed"
        Write-Host "changedPaths=0"
        Write-Host "headReceipt=$receipt"
        return
    }
    throw "No slice changes found in working tree or index."
}

$runtimeGovernanceArtifacts = @(
    "threshold/lease-state/current-run.json"
)
$effectiveChangedPaths = @($changedPaths | Where-Object { $runtimeGovernanceArtifacts -notcontains ($_ -replace "\\", "/") })
if (-not $effectiveChangedPaths -and -not $RequireHeadReceipt -and $changedPaths.Count -gt 0) {
    Write-Host "Threshold slice validation passed"
    Write-Host "changedPaths=$($changedPaths.Count)"
    Write-Host "effectiveChangedPaths=0"
    Write-Host "mavenTestSkipped=$($SkipMavenTest.IsPresent)"
    return
}

$governancePaths = @($effectiveChangedPaths | Where-Object { Test-GovernancePath $_ })
$fileBudget = $maxFiles
if ($governancePaths.Count -eq $effectiveChangedPaths.Count) { $fileBudget = $maxGovernanceFiles }
if ($effectiveChangedPaths.Count -gt $fileBudget) { throw "Slice changes $($effectiveChangedPaths.Count) files, exceeding file budget=$fileBudget." }

foreach ($path in $effectiveChangedPaths) {
    $isAllowed = $false
    foreach ($pattern in $allowedPaths) {
        if (Test-PathAgainstPattern $path $pattern) { $isAllowed = $true; break }
    }
    if (-not $isAllowed) { throw "Changed path is outside lease allowlist: $path" }

    foreach ($pattern in $forbiddenPaths) {
        if (Test-PathAgainstPattern $path $pattern) { throw "Changed path is forbidden by lease: $path" }
    }
}

$changedLineCount = 0
$numstat = & git diff --numstat
if (-not $numstat) { $numstat = & git diff --cached --numstat }
foreach ($line in $numstat) {
    $parts = $line -split "\s+"
    if ($parts.Count -ge 2 -and $parts[0] -match "^\d+$" -and $parts[1] -match "^\d+$") {
        $changedLineCount += [int]$parts[0] + [int]$parts[1]
    }
}
foreach ($path in $untrackedPaths) {
    if (Test-Path $path) { $changedLineCount += (Get-Content $path).Count }
}
$changedLineBudget = $maxChangedLines
if ($governancePaths.Count -eq $effectiveChangedPaths.Count) { $changedLineBudget = $maxGovernanceChangedLines }
if ($changedLineCount -gt $changedLineBudget) { throw "Slice changes $changedLineCount lines, exceeding changed-line budget=$changedLineBudget." }

& git diff --check
if ($LASTEXITCODE -ne 0) { throw "git diff --check failed." }

if (-not $SkipMavenTest) {
    $env:JAVA_HOME = $javaHome
    if (Test-Path ".\mvnw.cmd") { & .\mvnw.cmd test } else { & ./mvnw test }
    if ($LASTEXITCODE -ne 0) { throw "Maven test failed." }
}

Write-Host "Threshold slice validation passed"
Write-Host "changedPaths=$($effectiveChangedPaths.Count)"
Write-Host "changedLines=$changedLineCount"
Write-Host "mavenTestSkipped=$($SkipMavenTest.IsPresent)"
