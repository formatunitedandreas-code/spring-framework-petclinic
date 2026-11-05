[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GitFirstLine {
    param([string[]] $GitArgs)

    $output = @(& git @GitArgs)
    if ($output.Count -eq 0 -or $null -eq $output[0]) { return "" }
    return ([string]$output[0]).Trim()
}

function Invoke-Git {
    param([string[]] $GitArgs)

    $output = @(& git @GitArgs 2>&1)
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

function Write-Utf8NoBom {
    param([string] $Path, [string] $Value)

    [System.IO.File]::WriteAllText(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path),
        $Value,
        [System.Text.UTF8Encoding]::new($false)
    )
}

. (Join-Path $PSScriptRoot "lib/publication-preflight.ps1")

$originalLocation = Get-Location
$runtimeRoot = Join-Path $originalLocation "threshold/runtime/publication-toctou-isolated-fixture"
if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

try {
    Set-Location $runtimeRoot
    Invoke-Git -GitArgs @("init", "--initial-branch=main") | Out-Null
    Invoke-Git -GitArgs @("config", "user.email", "threshold-fixture@example.invalid") | Out-Null
    Invoke-Git -GitArgs @("config", "user.name", "Threshold Fixture") | Out-Null
    "base" | Set-Content -Path "base.txt" -Encoding UTF8
    Invoke-Git -GitArgs @("add", "base.txt") | Out-Null
    Invoke-Git -GitArgs @("commit", "-m", "base") | Out-Null

    $cliPath = Join-Path $runtimeRoot "detach-head-core-stub.js"
    $stub = @"
const { execFileSync } = require("child_process");
const fs = require("fs");
const crypto = require("crypto");
const hash = text => crypto.createHash("sha256").update(text).digest("hex");
if (process.argv[2] === "digest-publication-authority-input") {
  process.stdout.write(JSON.stringify({inputDigest:hash(fs.readFileSync(0,"utf8"))})); process.exit(0);
}
const inputText = fs.readFileSync(process.argv[process.argv.indexOf("--input") + 1], "utf8");
const head = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
execFileSync("git", ["switch", "--detach", "HEAD"], { stdio: "ignore" });
process.stdout.write(JSON.stringify({
  valid: true,
  evaluatedHead: head,
  inputDigest: hash(inputText),
  effectDecisions: {
    publication: { effect: "publication", allowed: true, disposition: "allowed", failedConstraintIds: [] }
  },
  failedConstraintIds: []
}) + "\n");
"@
    Write-Utf8NoBom -Path $cliPath -Value $stub

    Assert-ThrowsLike -Name "isolated-post-cli-head-detached" -Pattern "postvalidation_branch_changed" -ScriptBlock {
        $ThresholdCorePath = $runtimeRoot
        $ConsumedAuthorityPath = "consumed.json"
        $ReviewDecision = "APPROVED"
        $ReviewHead = (& git rev-parse HEAD).Trim()
        $targetCli = Join-Path $runtimeRoot "packages/refactoring-governor/dist/cli/thresholdRefactoringCliV0_1.js"
        New-Item -ItemType Directory -Path (Split-Path -Parent $targetCli) -Force | Out-Null
        Copy-Item -LiteralPath $cliPath -Destination $targetCli
        Write-Utf8NoBom "authority.json" '{}'
        Write-Utf8NoBom "consumed.json" '{"consumedConsumptionIds":[]}'
        Invoke-CanonicalPublicationAuthorityValidation -Path "authority.json" -RepositoryRef "fixture" -Branch "main" -SubjectRef "fixture" -Head $ReviewHead -WorkorderDigest "fixture" -PolicyDigest "fixture"
    }
}
finally {
    Set-Location $originalLocation
    if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
}

Write-Host "publicationToctouIsolatedFixture=passed"
