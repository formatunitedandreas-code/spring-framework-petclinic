[CmdletBinding()]
param(
    [string] $BaseRef = "main",
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name'" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function ConvertTo-RepoPath {
    param([string] $Path)

    $root = (git rev-parse --show-toplevel).Trim()
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($fullRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        return ($relative -replace "\\", "/")
    }
    return ($Path -replace "\\", "/")
}

function Test-LeasePath {
    param([string] $Path)

    $normalized = $Path -replace "\\", "/"
    return $normalized -like "threshold/leases/*"
}

function Test-ProductPath {
    param([string] $Path)

    $normalized = $Path -replace "\\", "/"
    return (
        $normalized -like "src/main/*" -or
        $normalized -like "src/test/*" -or
        $normalized -eq "pom.xml"
    )
}

function Assert-ChangedFilesMatchReceipt {
    param([string] $Commit, [pscustomobject] $Receipt)

    $actual = @(git diff-tree --no-commit-id --name-only -r $Commit | Sort-Object)
    $claimed = @(
        $Receipt.changedFiles | ForEach-Object {
            if ($_ -is [string]) {
                [string] $_
            }
            elseif ($null -ne $_.path) {
                [string] $_.path
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object
    )
    if ($claimed.Count -eq 0) {
        throw "Receipt for $Commit has no changedFiles paths."
    }
    if (($actual -join "`n") -ne ($claimed -join "`n")) {
        throw "Receipt changedFiles mismatch for $Commit. actual=[$($actual -join ', ')] claimed=[$($claimed -join ', ')]"
    }
}

function Get-CommitPathBlobSha256 {
    param([string] $Commit, [string] $Path)

    $spec = "$Commit`:$Path"
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "git"
    [void] $processInfo.ArgumentList.Add("cat-file")
    [void] $processInfo.ArgumentList.Add("blob")
    [void] $processInfo.ArgumentList.Add($spec)
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $buffer = [byte[]]::new(8192)
    try {
        while (($read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void] $sha256.TransformBlock($buffer, 0, $read, $null, 0)
        }
        [void] $sha256.TransformFinalBlock($buffer, 0, 0)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Failed to hash $Path at commit $Commit. $stderr"
        }
        return ([System.BitConverter]::ToString($sha256.Hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $process.Dispose()
    }
}

function Get-ReceiptCommit {
    param([string] $ReceiptPath)

    $receiptCommits = @(git log --format=%H "origin/${BaseRef}..HEAD" -- $ReceiptPath)
    if ($LASTEXITCODE -ne 0 -or $receiptCommits.Count -eq 0 -or [string]::IsNullOrWhiteSpace($receiptCommits[0])) {
        throw "Could not determine receipt commit for $ReceiptPath."
    }
    return ([string] $receiptCommits[0]).Trim()
}

function Assert-ReceiptLeaseDigestMatchesReceiptCommit {
    param([string] $ReceiptPath, [pscustomobject] $Receipt)

    if (-not $Receipt.leaseDigest) {
        throw "Receipt is missing leaseDigest: $ReceiptPath"
    }
    $receiptCommit = Get-ReceiptCommit -ReceiptPath $ReceiptPath
    $receiptLeaseDigest = Get-CommitPathBlobSha256 -Commit $receiptCommit -Path $LeasePath
    if ([string] $Receipt.leaseDigest -ne $receiptLeaseDigest) {
        throw "Receipt leaseDigest mismatch for $ReceiptPath at receipt commit $receiptCommit."
    }
}

if (-not (Test-Path $LeasePath)) {
    throw "Missing Threshold lease: $LeasePath"
}
if (-not (Test-Path $StatePath)) {
    throw "Missing lease state file: $StatePath"
}

$leaseLines = Get-Content $LeasePath
$allowedPaths = Get-ThresholdLeaseList -Lines $leaseLines -Name "allowedPaths"
$forbiddenPaths = Get-ThresholdLeaseList -Lines $leaseLines -Name "forbiddenPaths"
$expectedBaseRef = Get-LeaseScalar $leaseLines "baseRef"
$mergeAllowed = Get-LeaseScalar $leaseLines "mergeAllowed"
$forbiddenActions = @(Get-ThresholdLeaseList -Lines $leaseLines -Name "forbiddenActions")
if ($BaseRef -ne $expectedBaseRef.Replace("origin/", "")) {
    throw "PR base ref '$BaseRef' does not match threshold baseRef '$expectedBaseRef'."
}

$changedPaths = @(git diff --name-only "origin/${BaseRef}...HEAD")
if ($changedPaths.Count -eq 0) { throw "No changed paths detected for the pull request." }

$governancePolicyPaths = @($changedPaths | Where-Object { Test-ThresholdGovernancePolicyPath -Path $_ })
$leasePaths = @($changedPaths | Where-Object { Test-LeasePath $_ })
$productPaths = @($changedPaths | Where-Object { Test-ProductPath $_ })
if ($governancePolicyPaths.Count -gt 0 -and $productPaths.Count -gt 0) {
    throw "PR mixes governance policy and product paths; split into separate governed changes."
}

$requiresMergeAuthority = $governancePolicyPaths.Count -gt 0 -or ($leasePaths.Count -gt 0 -and $productPaths.Count -eq 0)
if ($requiresMergeAuthority) {
    if ($mergeAllowed -ne "true") {
        throw "Threshold governance policy/authority change does not authorize merge: mergeAllowed=$mergeAllowed."
    }
    if ($forbiddenActions -contains "merge") {
        throw "Threshold governance policy/authority change forbids merge via forbiddenActions."
    }
}

foreach ($path in $changedPaths) {
    $isAllowed = $false
    foreach ($pattern in $allowedPaths) {
        if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed -and -not (Test-ThresholdGovernancePath -Path $path)) {
        throw "Changed path is outside Threshold lease allowlist: $path"
    }
    foreach ($pattern in $forbiddenPaths) {
        if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
            throw "Changed path is forbidden by Threshold lease: $path"
        }
    }
}

$receiptPaths = @(Get-ChildItem threshold/receipts -Filter *.json -ErrorAction SilentlyContinue)
if ($receiptPaths.Count -eq 0) { throw "Missing Threshold receipt under threshold/receipts/*.json" }

$receiptByCommit = @{}
foreach ($receiptPath in $receiptPaths) {
    $receipt = Get-Content $receiptPath.FullName -Raw | ConvertFrom-Json
    $repoReceiptPath = ConvertTo-RepoPath -Path $receiptPath.FullName
    if ($receipt.PSObject.Properties["commitHash"] -and $receipt.commitHash) {
        $receiptByCommit[[string] $receipt.commitHash] = @{ path = $repoReceiptPath; receipt = $receipt }
    }
    elseif ($receipt.PSObject.Properties["sourceCommit"] -and $receipt.sourceCommit) {
        $receiptByCommit[[string] $receipt.sourceCommit] = @{ path = $repoReceiptPath; receipt = $receipt }
    }
}

$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if (-not $state.invocationId) { throw "Lease state is missing invocationId." }
if (-not $state.currentHead) { throw "Lease state is missing currentHead." }
if (-not $state.remainingBudget) { throw "Lease state is missing remainingBudget." }

$prCommits = @(git rev-list --reverse "origin/${BaseRef}..HEAD")
if ($prCommits.Count -eq 0) { throw "No PR commits detected." }

$sourceCommitCount = 0
foreach ($commit in $prCommits) {
    $commitPaths = @(git diff-tree --no-commit-id --name-only -r $commit)
    if ($commitPaths.Count -eq 0) { continue }

    $governanceOnly = $true
    foreach ($path in $commitPaths) {
        if (-not (Test-ThresholdGovernancePath -Path $path)) {
            $governanceOnly = $false
            break
        }
    }
    if ($governanceOnly) {
        Write-Host "Governance-only commit does not require self-referential receipt: $commit"
        continue
    }

    $sourceCommitCount += 1
    if (-not $receiptByCommit.ContainsKey($commit)) {
        throw "Source commit without corresponding Threshold receipt: $commit"
    }

    $entry = $receiptByCommit[$commit]
    $receipt = $entry.receipt
    if (-not $receipt.candidateId -and -not $receipt.batchId) { throw "Receipt is missing candidateId/batchId: $($entry.path)" }
    if (-not $receipt.baseHead) { throw "Receipt is missing baseHead: $($entry.path)" }
    if (-not $receipt.validation -or -not $receipt.validation.result) { throw "Receipt is missing validation result: $($entry.path)" }
    if (-not $receipt.nonClaims -or $receipt.nonClaims.Count -eq 0) { throw "Receipt is missing nonClaims: $($entry.path)" }
    Assert-ReceiptLeaseDigestMatchesReceiptCommit -ReceiptPath $entry.path -Receipt $receipt
    Assert-ChangedFilesMatchReceipt -Commit $commit -Receipt $receipt
}

if ($sourceCommitCount -eq 0 -and $productPaths.Count -gt 0) {
    throw "No source commit detected in PR range."
}

Write-Host "sourceCommitReceiptCoverage=complete"
Write-Host "thresholdGovernanceLabelRequired=false"
Write-Host "Threshold governance passed"
