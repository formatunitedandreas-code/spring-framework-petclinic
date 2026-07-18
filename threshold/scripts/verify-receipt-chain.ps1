[CmdletBinding()]
param(
    [string] $ReceiptRoot = "threshold/receipts",
    [string] $ChainPath = "threshold/attestations/receipt-chain.json",
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ReceiptTreeish = if (-not [string]::IsNullOrWhiteSpace($env:THRESHOLD_RECEIPT_TREEISH)) {
    [string]$env:THRESHOLD_RECEIPT_TREEISH
}
else {
    (& git rev-parse HEAD).Trim()
}

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function ConvertTo-RepoRelativePath {
    param([string] $Path)
    $repoRoot = (& git rev-parse --show-toplevel).Trim()
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($repoRoot)
    if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ConvertTo-RepoPath $resolved.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return ConvertTo-RepoPath $Path
}

function Get-FileSha256Lower {
    param([string] $Path)
    return ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash).ToLowerInvariant()
}

function Get-ReceiptGitBlobDigestLower {
    param([string] $Path)
    $repoPath = ConvertTo-RepoRelativePath $Path
    $blobDigest = (& git rev-parse "$($script:ReceiptTreeish):$repoPath" 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$blobDigest)) {
        return ([string]$blobDigest).Trim().ToLowerInvariant()
    }
    return Get-FileSha256Lower -Path $Path
}

function Get-ReceiptFilesSortedByRepoPath {
    param([string] $Root)
    $items = @(
        Get-ChildItem $Root -Filter *.json -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    File = $_
                    RepoPath = ConvertTo-RepoRelativePath $_.FullName
                }
            }
    )
    $sortedPaths = [string[]]@($items | ForEach-Object { $_.RepoPath })
    [array]::Sort($sortedPaths, [System.StringComparer]::Ordinal)
    return @($sortedPaths | ForEach-Object {
        $path = $_
        ($items | Where-Object { $_.RepoPath -eq $path } | Select-Object -First 1).File
    })
}

function Get-StringSha256Lower {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-JsonFile {
    param([string] $Path, [object] $Value)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $Value | ConvertTo-Json -Depth 16 | Set-Content $Path
}

$receiptFiles = @(Get-ReceiptFilesSortedByRepoPath -Root $ReceiptRoot)
if ($receiptFiles.Count -eq 0) { throw "receipt_chain_no_receipts" }

$previous = "".PadLeft(64, "0")
$entries = New-Object System.Collections.Generic.List[object]
foreach ($receiptFile in $receiptFiles) {
    $path = [string](ConvertTo-RepoRelativePath $receiptFile.FullName)
    $digest = [string](Get-ReceiptGitBlobDigestLower -Path $receiptFile.FullName)
    $linkInput = [string]::Concat($previous, "|", $path, "|", $digest)
    $link = Get-StringSha256Lower -Text $linkInput
    $entries.Add([ordered]@{
        path = $path
        receiptGitBlobDigest = $digest
        previousLink = $previous
        chainLink = $link
    })
    $previous = $link
}

$entryArray = @($entries.ToArray())
$chain = [ordered]@{
    schemaVersion = "threshold.petclinic.receipt-chain.v0.1"
    generatedAt = "deterministic-from-current-repo-state"
    gitHead = $ReceiptTreeish
    algorithm = "sha256(previousLink|path|receiptGitBlobDigest)"
    receiptCount = $entryArray.Count
    root = $previous
    entries = $entryArray
    nonClaims = @(
        "receipt chain is append-verifiable inside git history",
        "receipt chain is not external notarization",
        "receipt chain does not claim semantic correctness by itself"
    )
}

if ($CheckOnly.IsPresent) {
    if (-not (Test-Path $ChainPath)) { throw "receipt_chain_missing=$ChainPath" }
    $existing = Get-Content $ChainPath -Raw | ConvertFrom-Json
    if ([string]$existing.root -ne [string]$chain.root -or [int]$existing.receiptCount -ne [int]$chain.receiptCount) {
        throw "receipt_chain_stale=$ChainPath actualRoot=$($existing.root) expectedRoot=$($chain.root) actualCount=$($existing.receiptCount) expectedCount=$($chain.receiptCount)"
    }
}
else {
    Write-JsonFile -Path $ChainPath -Value $chain
}

Write-Host "receiptChain=$ChainPath"
Write-Host "receiptCount=$($entries.Count)"
Write-Host "receiptChainRoot=$previous"
