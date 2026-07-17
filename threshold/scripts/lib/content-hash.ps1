Set-StrictMode -Version Latest

function Get-ThresholdFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path $Path)) {
        throw "Cannot hash missing file: $Path"
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ThresholdGitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Revision,
        [Parameter(Mandatory = $true)][string] $Path
    )

    & git cat-file -e "$Revision`:$Path" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-git-blob-" + [guid]::NewGuid().ToString("N"))
    try {
        $process = Start-Process -FilePath "git" `
            -ArgumentList @("cat-file", "blob", "$Revision`:$Path") `
            -RedirectStandardOutput $tempPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        if ($process.ExitCode -ne 0) {
            throw "git cat-file blob failed for $Revision`:$Path"
        }
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash.ToLowerInvariant()
    }
    finally {
        if (Test-Path $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}
