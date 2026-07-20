[CmdletBinding()]
param(
    [string] $BaseRef = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TextSha256 {
    param([string] $Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-RepositoryRef {
    $remoteUrl = (& git remote get-url origin).Trim()
    if ($remoteUrl -match "github.com[:/](.+?)(\.git)?$") {
        return $Matches[1] -replace "\.git$", ""
    }
    return $remoteUrl
}

function Get-PolicyDigest {
    $policyPaths = @(
        "threshold/policies/file-economy-v0.1.yaml",
        "threshold/policies/semantic-twin-v0.1.yaml",
        "threshold/policies/senior-refactoring-admission-v0.1.yaml",
        "threshold/policies/target-twin-v0.1.yaml"
    ) | Where-Object { Test-Path $_ }
    $content = @($policyPaths | Sort-Object | ForEach-Object { "$_`n$(Get-Content $_ -Raw)" }) -join "`n---threshold-policy---`n"
    return Get-TextSha256 -Value $content
}

function Get-SubjectDigest {
    param([string] $Head)
    $changed = @(& git diff --name-only "origin/${BaseRef}...HEAD" | Sort-Object)
    return Get-TextSha256 -Value ((@($Head) + $changed) -join "`n")
}

function Invoke-Preflight {
    param(
        [string] $AuthorityPath,
        [string] $ConsumedAuthorityPath,
        [string] $ReviewHead,
        [string] $ReviewDecision = "APPROVED",
        [int] $OpenP1P2Count = 0
    )

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-pr-governance.ps1" `
        -BaseRef $BaseRef `
        -PublicationPreflight `
        -AuthorityPath $AuthorityPath `
        -ConsumedAuthorityPath $ConsumedAuthorityPath `
        -ReviewHead $ReviewHead `
        -ReviewDecision $ReviewDecision `
        -OpenP1P2Count $OpenP1P2Count 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
    return $output
}

function Assert-ThrowsLike {
    param(
        [string] $Name,
        [string] $Pattern,
        [scriptblock] $ScriptBlock
    )

    try {
        & $ScriptBlock
    }
    catch {
        if ([string]$_.Exception.Message -match $Pattern) {
            Write-Host "expectedStop=$Name"
            return
        }
        throw "Unexpected stop for ${Name}: $($_.Exception.Message)"
    }
    throw "Expected stop did not occur: $Name"
}

function Write-Authority {
    param(
        [string] $Path,
        [hashtable] $Overrides = @{}
    )

    $head = (& git rev-parse HEAD).Trim()
    $branch = (& git branch --show-current).Trim()
    $authority = [ordered]@{
        schemaVersion = "threshold.one-shot-authority.v0.1"
        authorityId = "authority:publication-preflight:test"
        repositoryRef = Get-RepositoryRef
        branchRef = $branch
        subjectRef = "pull-request:$branch->$BaseRef"
        headSha = $head
        workorderDigest = Get-SubjectDigest -Head $head
        policyDigest = Get-PolicyDigest
        action = "merge"
        issuer = "fixture:publication-preflight"
        issuedAt = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("o")
        expiresAt = (Get-Date).ToUniversalTime().AddMinutes(30).ToString("o")
        consumptionId = "consume:publication-preflight:test"
        nonClaims = @("one-shot authority is not reusable")
    }
    foreach ($key in $Overrides.Keys) {
        $authority[$key] = $Overrides[$key]
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $authority | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

$runtimeRoot = "threshold/runtime/publication-preflight-fixtures"
$authorityPath = "$runtimeRoot/merge-authority.json"
$consumedPath = "$runtimeRoot/consumed-authorities.json"
if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

$head = (& git rev-parse HEAD).Trim()

Assert-ThrowsLike -Name "missing-authority" -Pattern "stop_authority_missing" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head
}

Write-Authority -Path $authorityPath
Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head | Out-Null
Write-Host "publicationPreflightFixture=valid-authority-passed"

Write-Authority -Path $authorityPath -Overrides @{ headSha = "stale-head" }
Assert-ThrowsLike -Name "wrong-head-authority" -Pattern "stop_authority_mismatch=headSha" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head
}

Write-Authority -Path $authorityPath -Overrides @{ branchRef = "codex/wrong-branch" }
Assert-ThrowsLike -Name "wrong-branch-authority" -Pattern "stop_authority_mismatch=branchRef" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head
}

Write-Authority -Path $authorityPath -Overrides @{ expiresAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o") }
Assert-ThrowsLike -Name "expired-authority" -Pattern "stop_authority_expired" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head
}

Write-Authority -Path $authorityPath
@{ consumedConsumptionIds = @("consume:publication-preflight:test") } | ConvertTo-Json -Depth 4 | Set-Content -Path $consumedPath -Encoding UTF8
Assert-ThrowsLike -Name "consumed-authority" -Pattern "stop_authority_consumed" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head
}
Remove-Item -Force $consumedPath

Write-Authority -Path $authorityPath
Assert-ThrowsLike -Name "stale-review-head" -Pattern "stop_review_stale_head" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead "stale-review-head"
}

Assert-ThrowsLike -Name "open-p1-p2-findings" -Pattern "stop_open_p1_p2_findings=1" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -OpenP1P2Count 1
}

Remove-Item -Recurse -Force $runtimeRoot
Write-Host "publicationPreflightFixtures=passed"
