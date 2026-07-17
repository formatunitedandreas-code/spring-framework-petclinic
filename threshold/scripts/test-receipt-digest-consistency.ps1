[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$originalLocation = Get-Location
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-receipt-digest-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Set-Location $tempRoot
    & git init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    & git config user.email "threshold-canary@example.invalid"
    & git config user.name "Threshold Canary"

    New-Item -ItemType Directory -Path "threshold/leases" -Force | Out-Null
    New-Item -ItemType Directory -Path "threshold/receipts" -Force | Out-Null
    New-Item -ItemType Directory -Path "threshold/lease-state" -Force | Out-Null
    New-Item -ItemType Directory -Path "src/main/java/demo" -Force | Out-Null

    $leasePath = "threshold/leases/current.yaml"
    $leaseContent = @(
        "leaseName: digest-canary"
        "branch: main"
        "baseRef: origin/main"
        "startHead: pending"
        "originMainAtActivation: pending"
        "headPolicy: descendantOfStartHead"
        "allowedPaths:"
        "  - src/main/**"
        "forbiddenPaths:"
        "  - threshold/scripts/**"
        "forbiddenActions:"
        "  - release"
        "  - deploy"
        "terminalBoundary:"
        "  draftPrAllowed: true"
        "  mergeAllowed: true"
    ) -join "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $leasePath), $leaseContent + "`n", $utf8NoBom)

    Set-Content -Path "src/main/java/demo/App.java" -NoNewline -Value "class App { }"
    & git add -- $leasePath "src/main/java/demo/App.java"
    & git commit -m "Initial canary commit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
    $initialHead = (& git rev-parse HEAD).Trim()

    $updatedLeaseContent = $leaseContent.Replace("startHead: pending", "startHead: $initialHead").Replace("originMainAtActivation: pending", "originMainAtActivation: $initialHead")
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $leasePath), $updatedLeaseContent + "`n", $utf8NoBom)
    Set-Content -Path "src/main/java/demo/App.java" -NoNewline -Value "class App { int v = 1; }"
    & git add -- $leasePath "src/main/java/demo/App.java"
    & git commit -m "Source canary commit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "source commit failed" }
    $sourceCommit = (& git rev-parse HEAD).Trim()
    $baseHead = (& git rev-parse "$sourceCommit^").Trim()

    $crlfLeaseContent = ($updatedLeaseContent -replace "`n", "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $leasePath), $crlfLeaseContent, $utf8NoBom)
    $worktreeLeaseDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $leasePath).Hash.ToLowerInvariant()

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/dev/spring-framework-petclinic/threshold/scripts/record-receipt.ps1" `
        -LeasePath $leasePath `
        -StatePath "threshold/lease-state/current-run.json" `
        -CandidateId "digest-canary" `
        -CommitHash $sourceCommit `
        -BaseHead $baseHead `
        -ValidationResult "BUILD SUCCESS" `
        -TestsRun 1 `
        -UpdateState
    if ($LASTEXITCODE -ne 0) { throw "record-receipt.ps1 failed" }

    $receiptPath = "threshold/receipts/digest-canary-$($sourceCommit.Substring(0, 12)).json"
    if (-not (Test-Path $receiptPath)) {
        throw "expected receipt not created: $receiptPath"
    }

    $receipt = Get-Content $receiptPath -Raw | ConvertFrom-Json
    $blobTempPath = Join-Path $tempRoot "lease-blob.bin"
    try {
        $blobProcess = Start-Process -FilePath "git" `
            -ArgumentList @("cat-file", "blob", "$sourceCommit`:$leasePath") `
            -RedirectStandardOutput $blobTempPath `
            -NoNewWindow `
            -Wait `
            -PassThru
        if ($blobProcess.ExitCode -ne 0) { throw "git cat-file blob failed in test" }
        $blobDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $blobTempPath).Hash.ToLowerInvariant()
    }
    finally {
        if (Test-Path $blobTempPath) {
            Remove-Item -LiteralPath $blobTempPath -Force
        }
    }

    if ($receipt.leaseDigest -ne $blobDigest) {
        throw "receipt leaseDigest does not match committed lease blob digest"
    }
    if ($receipt.leaseDigest -eq $worktreeLeaseDigest) {
        throw "receipt leaseDigest unexpectedly matched CRLF worktree digest"
    }

    Write-Host "passed=receipt leaseDigest uses committed blob digest"
    Write-Host "thresholdReceiptDigestConsistency=passed"
}
finally {
    Set-Location $originalLocation
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
