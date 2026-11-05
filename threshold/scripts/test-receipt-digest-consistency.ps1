[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")
. (Join-Path $PSScriptRoot "lib/content-hash.ps1")

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

    $javaPath = "src/main/java/demo/App.java"
    $javaBefore = @(
        "package org.example;", "", "import java.util.Locale;", "",
        "class App {", "    public String print(Locale locale) {",
        "        return locale.toLanguageTag();", "    }", "",
        "    public String parse(String text) {", "        return text;", "    }", "}"
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $javaPath), $javaBefore + "`n", $utf8NoBom)
    & git add -- $leasePath $javaPath
    & git commit -m "Initial canary commit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
    $initialHead = (& git rev-parse HEAD).Trim()
    $updatedLeaseContent = $leaseContent.Replace("startHead: pending", "startHead: $initialHead").Replace("originMainAtActivation: pending", "originMainAtActivation: $initialHead")
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $leasePath), $updatedLeaseContent + "`n", $utf8NoBom)
    & git add -- $leasePath
    & git commit -m "Bind canary lease" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "lease commit failed" }
    $discoverySourceHead = (& git rev-parse HEAD).Trim()
    $pocketPath = "method-pocket.json"
    [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
        generatedFromHead = $discoverySourceHead
        candidates = @([ordered]@{
            candidateId = "digest-canary"
            candidateClass = "method_spacing_normalization"
            file = $javaPath
            member = "line-9"
            spacingAction = "collapse_extra_blank_line"
        })
    } | ConvertTo-Json -Depth 6 | Set-Content $pocketPath
    $discoveryPath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot "discovery-evidence" -CandidateId "digest-canary" -BaseHead $discoverySourceHead
    $discovery = New-ThresholdCandidateDiscoveryEvidence -BaseHead $discoverySourceHead -CandidateId "digest-canary" -CandidatePocketPath $pocketPath
    Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $discovery -Path $discoveryPath
    & git add -- $pocketPath $discoveryPath
    & git commit -m "Bind pre-product discovery evidence" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "discovery commit failed" }
    $baseHead = (& git rev-parse HEAD).Trim()
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $javaPath), $javaBefore.Replace("    }`n`n    public", "    }`n    public") + "`n", $utf8NoBom)
    & git add -- $javaPath
    & git commit -m "Normalize method boundary spacing" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "source commit failed" }
    $sourceCommit = (& git rev-parse HEAD).Trim()
    [System.IO.File]::AppendAllText((Join-Path $tempRoot $leasePath), "# metadata after requested source commit`n", $utf8NoBom)
    & git add -- $leasePath
    & git commit -m "Advance metadata beyond source commit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "metadata commit failed" }

    $crlfLeaseContent = ($updatedLeaseContent -replace "`n", "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $tempRoot $leasePath), $crlfLeaseContent, $utf8NoBom)
    $worktreeLeaseDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $leasePath).Hash.ToLowerInvariant()

    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot "record-receipt.ps1") `
        -LeasePath $leasePath `
        -StatePath "threshold/lease-state/current-run.json" `
        -CandidateId "digest-canary" `
        -CandidateClass "method_spacing_normalization" `
        -PrBaseHead $baseHead `
        -CandidatePocketPath $pocketPath `
        -DiscoveryEvidencePath $discoveryPath `
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

    & git add -- $receiptPath
    & git commit -m "Materialize source-bound receipt after metadata drift" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "receipt commit failed" }
    $receiptCommit = (& git rev-parse HEAD).Trim()
    Assert-ThresholdReceiptLeaseDigest -Receipt $receipt -LeasePath $leasePath -ReceiptCommit $receiptCommit
    if ([string]$receipt.leaseDigestRevision -cne $sourceCommit) { throw "Receipt revision must be the requested source commit" }

    $legacy = $receipt | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $legacy.PSObject.Properties.Remove("leaseDigestRevision")
    $legacy.leaseDigest = Get-ThresholdGitBlobSha256 -Revision $receiptCommit -Path $leasePath
    Assert-ThresholdReceiptLeaseDigest -Receipt $legacy -LeasePath $leasePath -ReceiptCommit $receiptCommit

    foreach ($tamper in @("sourceDigestWithoutRevision", "foreignRevision")) {
        $bad = $receipt | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        if ($tamper -eq "sourceDigestWithoutRevision") { $bad.PSObject.Properties.Remove("leaseDigestRevision") }
        else { $bad.leaseDigestRevision = $receiptCommit }
        $rejected = $false
        try { Assert-ThresholdReceiptLeaseDigest -Receipt $bad -LeasePath $leasePath -ReceiptCommit $receiptCommit }
        catch { $rejected = $true }
        if (-not $rejected) { throw "Invalid receipt digest binding accepted: $tamper" }
    }
    Write-Host "passed=production validator accepts explicit source revision and legacy receipt revision, rejects tampering"
    Write-Host "passed=receipt leaseDigest uses committed blob digest"
    Write-Host "thresholdReceiptDigestConsistency=passed"
}
finally {
    Set-Location $originalLocation
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
