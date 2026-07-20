[CmdletBinding()]
param(
    [string] $BaseRef = "main",
    [string] $ThresholdCorePath = $env:THRESHOLD_CORE_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GitFirstLine {
    param([string[]] $GitArgs)

    $output = @(& git @GitArgs)
    if ($output.Count -eq 0 -or $null -eq $output[0]) { return "" }
    return ([string]$output[0]).Trim()
}

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
        [int] $OpenP1P2Count = 0,
        [string] $CorePath = $ThresholdCorePath
    )

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-pr-governance.ps1" `
        -BaseRef $BaseRef `
        -PublicationPreflight `
        -AuthorityPath $AuthorityPath `
        -ConsumedAuthorityPath $ConsumedAuthorityPath `
        -ThresholdCorePath $CorePath `
        -ReviewHead $ReviewHead `
        -ReviewDecision $ReviewDecision `
        -OpenP1P2Count $OpenP1P2Count 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
    return $output
}

if ([string]::IsNullOrWhiteSpace($ThresholdCorePath)) {
    $repoRoot = (& git rev-parse --show-toplevel).Trim()
    $candidate = Join-Path (Split-Path -Parent $repoRoot) "threshold-ai-slim"
    if (Test-Path (Join-Path $candidate "packages/refactoring-governor/package.json")) {
        $ThresholdCorePath = $candidate
    }
}
if ([string]::IsNullOrWhiteSpace($ThresholdCorePath)) {
    throw "threshold_core_path_required_for_publication_preflight_fixtures"
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
    $branch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
    $authority = [ordered]@{
        schemaVersion = "threshold.one-shot-authority.v0.1"
        authorityId = "authority:publication-preflight:test"
        repositoryRef = Get-RepositoryRef
        branchRef = $branch
        subjectRef = "pull-request:$branch->$BaseRef"
        headSha = $head
        workorderDigest = Get-SubjectDigest -Head $head
        policyDigest = Get-PolicyDigest
        action = "push"
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

function New-StubCore {
    param([string] $Root, [string] $Mode = "valid")

    $cliDir = Join-Path $Root "packages/refactoring-governor/dist/cli"
    if (-not (Test-Path $cliDir)) { New-Item -ItemType Directory -Path $cliDir | Out-Null }
    $cliPath = Join-Path $cliDir "thresholdRefactoringCliV0_1.js"
    $script = @"
#!/usr/bin/env node
const fs = require("fs");
const { execFileSync } = require("child_process");
const mode = process.env.THRESHOLD_STUB_CORE_MODE || "$Mode";
const inputPath = process.argv[process.argv.indexOf("--input") + 1];
const inputText = fs.readFileSync(inputPath, "utf8").replace(/^\uFEFF/, "");
const input = JSON.parse(inputText);
const head = input.context.headSha;
const digest = "fixture-input-digest";
function decision(effect, allowed, failedConstraintIds) {
  return { effect, allowed, disposition: allowed ? "allowed" : "stop_no_action", failedConstraintIds };
}
function output(value, exitCode) {
  process.stdout.write(JSON.stringify(value, null, 2) + "\n");
  process.exitCode = exitCode;
}
if (mode === "multi-json") {
  process.stdout.write(JSON.stringify({ valid: true }) + "\n" + JSON.stringify({ valid: true }) + "\n");
  process.exitCode = 0;
} else if (mode === "detach-head") {
  execFileSync("git", ["switch", "--detach", "HEAD"], { stdio: "ignore" });
  output({
    valid: true,
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: []
  }, 0);
} else if (mode === "missing-typed") {
  output({ valid: true, evaluatedHead: head, reasonCodes: ["diagnostic_only"] }, 0);
} else if (mode === "unknown-field") {
  output({
    valid: true,
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: [],
    unexpectedDecisionSurface: "must-fail-closed"
  }, 0);
} else if (mode === "wrong-evaluated-head") {
  output({
    valid: true,
    evaluatedHead: "0000000000000000000000000000000000000000",
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: []
  }, 0);
} else if (mode === "valid-reason-renamed") {
  output({
    valid: true,
    decision: "legacy_label_renamed_must_not_decide",
    reasonCodes: ["stop_authority_expired", "renamed_diagnostic_only"],
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: []
  }, 0);
} else if (mode === "valid-reason-ablation") {
  output({
    valid: true,
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: []
  }, 0);
} else if (mode.startsWith("publication-blocked")) {
  const constraintByMode = {
    "publication-blocked-reason-allowed": "publication-head-binding",
    "publication-blocked-head": "publication-head-binding",
    "publication-blocked-branch": "publication-branch-binding",
    "publication-blocked-expired": "publication-authority-expiry",
    "publication-blocked-consumed": "publication-authority-unconsumed",
    "publication-blocked-action": "one-shot-authority-action-binding"
  };
  const failed = [constraintByMode[mode] || "publication-head-binding"];
  output({
    valid: false,
    decision: "publication_authority_satisfied",
    reasonCodes: ["publication_authority_satisfied", "interference_finding_visible"],
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", false, failed),
      merge: decision("merge", false, failed)
    },
    failedConstraintIds: failed
  }, 2);
} else {
  output({
    valid: true,
    decision: "publication_authority_satisfied",
    reasonCodes: ["diagnostic_only"],
    evaluatedHead: head,
    inputDigest: digest,
    effectDecisions: {
      observe: decision("observe", true, []),
      localExperiment: decision("localExperiment", true, []),
      shadowIntegration: decision("shadowIntegration", true, []),
      publication: decision("publication", true, []),
      merge: decision("merge", true, [])
    },
    failedConstraintIds: []
  }, 0);
}
"@
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($cliPath),
        $script,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $Root
}

function Invoke-WithStubCoreMode {
    param([string] $Mode, [scriptblock] $ScriptBlock)

    $previous = $env:THRESHOLD_STUB_CORE_MODE
    $env:THRESHOLD_STUB_CORE_MODE = $Mode
    try {
        & $ScriptBlock
    }
    finally {
        if ($null -eq $previous) {
            Remove-Item Env:\THRESHOLD_STUB_CORE_MODE -ErrorAction SilentlyContinue
        }
        else {
            $env:THRESHOLD_STUB_CORE_MODE = $previous
        }
    }
}

$runtimeRoot = "threshold/runtime/publication-preflight-fixtures"
$authorityPath = "$runtimeRoot/publication-authority.json"
$consumedPath = "$runtimeRoot/consumed-authorities.json"
if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
$stubCorePath = New-StubCore -Root (Join-Path $runtimeRoot "stub-core")

$head = (& git rev-parse HEAD).Trim()
$originalBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")

Assert-ThrowsLike -Name "missing-authority" -Pattern "stop_authority_missing" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
}

Write-Authority -Path $authorityPath
Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath | Out-Null
Write-Host "publicationPreflightFixture=valid-authority-passed"

Invoke-WithStubCoreMode -Mode "valid-reason-renamed" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath | Out-Null
}
Write-Host "publicationPreflightFixture=reason-renaming-does-not-decide"

Invoke-WithStubCoreMode -Mode "valid-reason-ablation" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath | Out-Null
}
Write-Host "publicationPreflightFixture=reason-ablation-does-not-decide"

Write-Authority -Path $authorityPath -Overrides @{ action = "merge" }
Assert-ThrowsLike -Name "merge-authority-not-publication" -Pattern "stop_authority_mismatch=action" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-action" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Write-Authority -Path $authorityPath

Write-Authority -Path $authorityPath -Overrides @{ headSha = "stale-head" }
Assert-ThrowsLike -Name "wrong-head-authority" -Pattern "stop_authority_mismatch=headSha" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-head" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Write-Authority -Path $authorityPath -Overrides @{ branchRef = "codex/wrong-branch" }
Assert-ThrowsLike -Name "wrong-branch-authority" -Pattern "stop_authority_mismatch=branchRef" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-branch" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Write-Authority -Path $authorityPath -Overrides @{ branchRef = "threshold-governed-refactor-demo-184" }
Assert-ThrowsLike -Name "stale-legacy-lease-branch" -Pattern "stop_authority_mismatch=branchRef" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-branch" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Write-Authority -Path $authorityPath -Overrides @{ expiresAt = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString("o") }
Assert-ThrowsLike -Name "expired-authority" -Pattern "stop_authority_expired" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-expired" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Write-Authority -Path $authorityPath
@{ consumedConsumptionIds = @("consume:publication-preflight:test") } | ConvertTo-Json -Depth 4 | Set-Content -Path $consumedPath -Encoding UTF8
Assert-ThrowsLike -Name "consumed-authority" -Pattern "stop_authority_consumed" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-consumed" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}
Remove-Item -Force $consumedPath

Write-Authority -Path $authorityPath
Assert-ThrowsLike -Name "stale-review-head" -Pattern "stop_review_stale_head" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead "stale-review-head" -CorePath $stubCorePath
}

Assert-ThrowsLike -Name "open-p1-p2-findings" -Pattern "stop_open_p1_p2_findings=1" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -OpenP1P2Count 1 -CorePath $stubCorePath
}

Assert-ThrowsLike -Name "core-cli-missing" -Pattern "stop_authority_validator_unavailable=.*canonical validator CLI not found" -ScriptBlock {
    Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath (Join-Path $runtimeRoot "missing-core")
}

Assert-ThrowsLike -Name "multiple-json-values" -Pattern "multiple JSON documents" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "multi-json" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Assert-ThrowsLike -Name "missing-typed-fields" -Pattern "inputDigest_missing|effectDecisions_missing|failedConstraintIds_missing" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "missing-typed" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Assert-ThrowsLike -Name "unknown-core-field" -Pattern "unknown_field=unexpectedDecisionSurface" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "unknown-field" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Assert-ThrowsLike -Name "validator-evaluated-different-head" -Pattern "evaluatedHead_mismatch" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "wrong-evaluated-head" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

Assert-ThrowsLike -Name "typed-publication-blocked-reason-string-allowed" -Pattern "stop_authority_mismatch=headSha" -ScriptBlock {
    Invoke-WithStubCoreMode -Mode "publication-blocked-reason-allowed" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}

$gitWriteProbePath = ".git/threshold-publication-preflight-write-probe.tmp"
$gitMetadataWritable = $false
try {
    "probe" | Set-Content -Path $gitWriteProbePath -Encoding UTF8
    Remove-Item -Force $gitWriteProbePath
    $gitMetadataWritable = $true
}
catch {
    if (Test-Path $gitWriteProbePath) { Remove-Item -Force $gitWriteProbePath -ErrorAction SilentlyContinue }
}
if ($gitMetadataWritable) {
    Assert-ThrowsLike -Name "post-cli-head-detached" -Pattern "postvalidation_branch_changed" -ScriptBlock {
        try {
            Invoke-WithStubCoreMode -Mode "detach-head" -ScriptBlock {
                Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
            }
        }
        finally {
            git switch $originalBranch | Out-Null
        }
    }
}
else {
    Write-Host "publicationPreflightFixture=post-cli-head-detached-skipped-readonly-git"
}

try {
    Invoke-WithStubCoreMode -Mode "publication-blocked-reason-allowed" -ScriptBlock {
        Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
    }
}
catch {
    $resultText = if (Test-Path "threshold/runtime/authority-validation/publication-authority-result.json") {
        Get-Content "threshold/runtime/authority-validation/publication-authority-result.json" -Raw
    }
    else {
        [string]$_.Exception.Message
    }
    if ($resultText -notmatch "interference_finding_visible") {
        throw "interference_finding_not_visible_after_authority_stop"
    }
    Write-Host "publicationPreflightFixture=interference-finding-visible"
}

Remove-Item -Recurse -Force $runtimeRoot
Write-Host "publicationPreflightFixtures=passed"
