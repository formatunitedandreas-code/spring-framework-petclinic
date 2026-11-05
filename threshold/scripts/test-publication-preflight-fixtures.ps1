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

    . (Join-Path $PSScriptRoot "lib/publication-preflight.ps1")
    $ThresholdCorePath = $CorePath
    $changed = @(& git diff --name-only "origin/${BaseRef}...HEAD")
    Assert-PublicationPreflight -ChangedPaths $changed

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
        fixtureMarker = "Grüße_日本語_😀"
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
const crypto = require("crypto");
const hash = value => crypto.createHash("sha256").update(value).digest("hex");
if (process.argv[2] === "digest-publication-authority-input") {
  const originalText = fs.readFileSync(0, "utf8");
  const original = JSON.parse(originalText);
  if (original.authority.fixtureMarker !== "Grüße_日本語_😀") throw Error("UTF8 stdin altered");
  process.stdout.write(JSON.stringify({inputDigest:hash(originalText)}));
  process.exit(0);
}
const inputPath = process.argv[process.argv.indexOf("--input") + 1];
const inputText = fs.readFileSync(inputPath, "utf8").replace(/^\uFEFF/, "");
const input = JSON.parse(inputText);
const head = input.context.headSha;
let digest = hash(inputText);
if (mode === "wrong-digest") digest = "0".repeat(64);
if (mode === "input-substitution") {
  input.context.policyDigest = "substituted";
  const substituted = JSON.stringify(input);
  fs.writeFileSync(inputPath, substituted);
  digest = hash(substituted);
}
function decision(effect, allowed, failedConstraintIds) {
  return { effect, allowed, disposition: allowed ? "allowed" : "stop_no_action", failedConstraintIds };
}
function output(value, exitCode) {
  if (mode === "wrong-effect") value.effectDecisions.publication.effect = "merge";
  if (mode === "wrong-disposition") value.effectDecisions.publication.disposition = "blocked";
  if (mode === "null-array") value.failedConstraintIds = null;
  if (mode === "string-array") value.failedConstraintIds = "not-an-array";
  if (mode === "object-array") value.failedConstraintIds = {};
  if (mode === "failed-allow") value.failedConstraintIds = ["publication-head-binding"];
  if (mode === "exit-failure") exitCode = 2;
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
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($cliPath),
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

# Publication is deliberately forbidden from a detached checkout. Test the
# production consumer in a separate repository with a real branch, including CI.
$originalLocation = Get-Location
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-publication-" + [guid]::NewGuid().ToString("N"))
$policySource = Join-Path $PSScriptRoot "../policies"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    Set-Location $fixtureRoot
    & git init --initial-branch=main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "publication_fixture_init_failed" }
    & git config user.email "threshold-fixture@example.invalid"
    & git config user.name "Threshold Fixture"
    & git config core.longpaths true
    & git remote add origin https://github.com/example/publication-fixture.git
    New-Item -ItemType Directory threshold/policies -Force | Out-Null
    Copy-Item -Path (Join-Path $policySource "*.yaml") -Destination threshold/policies
    & git add threshold/policies
    & git commit -m "Publication fixture base" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "publication_fixture_commit_failed" }
    & git update-ref refs/remotes/origin/main HEAD
    $BaseRef = "main"
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
@{ consumedConsumptionIds = @() } | ConvertTo-Json -Depth 4 | Set-Content -Path $consumedPath -Encoding UTF8
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
@{ consumedConsumptionIds = @() } | ConvertTo-Json -Depth 4 | Set-Content -Path $consumedPath -Encoding UTF8

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

foreach ($case in @(
    @{ mode = "wrong-digest"; pattern = "inputDigest_mismatch" },
    @{ mode = "input-substitution"; pattern = "inputDigest_mismatch" },
    @{ mode = "wrong-effect"; pattern = "publication_effect_mismatch" },
    @{ mode = "wrong-disposition"; pattern = "publication_disposition_mismatch" },
    @{ mode = "null-array"; pattern = "invalid_array" },
    @{ mode = "string-array"; pattern = "invalid_array" },
    @{ mode = "object-array"; pattern = "invalid_array" },
    @{ mode = "failed-allow"; pattern = "allowed_with_failed_constraints" },
    @{ mode = "exit-failure"; pattern = "validator_failed_with_allow_result" }
)) {
    Assert-ThrowsLike -Name $case.mode -Pattern $case.pattern -ScriptBlock {
        Invoke-WithStubCoreMode -Mode $case.mode -ScriptBlock {
            Invoke-Preflight -AuthorityPath $authorityPath -ConsumedAuthorityPath $consumedPath -ReviewHead $head -CorePath $stubCorePath
        }
    }
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
$global:LASTEXITCODE = 0 # The final denied authority is an expected negative case.

}
finally {
    Set-Location $originalLocation
    # This invocation created this exact absolute directory for fixture use.
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
