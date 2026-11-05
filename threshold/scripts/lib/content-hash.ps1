Set-StrictMode -Version Latest

function Get-ThresholdFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Cannot hash missing file: $Path" }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ThresholdGitBlobSha256 {
    param([string] $Revision, [string] $Path)
    $repoPath = ($Path -replace "\\", "/").Trim()
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git cat-file -e "$Revision`:$repoPath" 2>$null
    $exists = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previousErrorActionPreference
    if (-not $exists) { return $null }

    $spec = "$Revision`:$repoPath"
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "git"
    $processInfo.WorkingDirectory = (Get-Location).ProviderPath
    $argumentListProperty = $processInfo.GetType().GetProperty("ArgumentList")
    if ($null -ne $argumentListProperty) {
        [void] $processInfo.ArgumentList.Add("cat-file")
        [void] $processInfo.ArgumentList.Add("blob")
        [void] $processInfo.ArgumentList.Add($spec)
    }
    else {
        $escapedSpec = $spec.Replace('"', '\"')
        $processInfo.Arguments = "cat-file blob `"$escapedSpec`""
    }
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
            throw "Failed to hash git blob: $spec. $stderr"
        }
        return ([System.BitConverter]::ToString($sha256.Hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $process.Dispose()
    }
}

function Assert-ThresholdReceiptLeaseDigest {
    param(
        [Parameter(Mandatory = $true)][pscustomobject] $Receipt,
        [Parameter(Mandatory = $true)][string] $LeasePath,
        [Parameter(Mandatory = $true)][string] $ReceiptCommit
    )
    if (-not $Receipt.leaseDigest) { throw "Receipt is missing leaseDigest." }
    $revision = $ReceiptCommit
    if ($Receipt.PSObject.Properties["leaseDigestRevision"]) {
        $revision = [string]$Receipt.leaseDigestRevision
        $sourceCommit = if ($Receipt.PSObject.Properties["commitHash"]) { [string]$Receipt.commitHash } elseif ($Receipt.PSObject.Properties["sourceCommit"]) { [string]$Receipt.sourceCommit } else { "" }
        if ($revision -cnotmatch '^[0-9a-f]{40}$' -or $revision -cne $sourceCommit) {
            throw "Receipt leaseDigestRevision must bind its exact source commit."
        }
        & git merge-base --is-ancestor $revision $ReceiptCommit
        if ($LASTEXITCODE -ne 0) { throw "Receipt lease digest source revision is not an ancestor of its receipt commit." }
    }
    $expectedDigest = Get-ThresholdGitBlobSha256 -Revision $revision -Path $LeasePath
    if ([string]::IsNullOrWhiteSpace($expectedDigest) -or [string]$Receipt.leaseDigest -ne $expectedDigest) {
        throw "Receipt leaseDigest mismatch at revision $revision."
    }
}
