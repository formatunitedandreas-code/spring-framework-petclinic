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
        [System.IO.Path]::GetFullPath($Path),
        $Value,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-IsolatedCoreValidation {
    param([string] $CliPath)

    $preValidationHead = (& git rev-parse HEAD).Trim()
    $preValidationBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($preValidationBranch)) {
        throw "stop_authority_toctou=prevalidation_detached_head"
    }
    $preValidationTree = (& git rev-parse "$preValidationHead^{tree}").Trim()

    $output = @(& node $CliPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
    $result = (($output | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
    if ([string]$result.evaluatedHead -ne $preValidationHead) {
        throw "stop_authority_toctou=evaluatedHead_mismatch"
    }

    $postValidationHead = (& git rev-parse HEAD).Trim()
    $postValidationBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
    $postValidationTree = (& git rev-parse "$postValidationHead^{tree}").Trim()
    if ($postValidationHead -ne $preValidationHead) {
        throw "stop_authority_toctou=postvalidation_head_changed"
    }
    if ([string]::IsNullOrWhiteSpace($postValidationBranch) -or $postValidationBranch -ne $preValidationBranch) {
        throw "stop_authority_toctou=postvalidation_branch_changed"
    }
    if ($postValidationTree -ne $preValidationTree) {
        throw "stop_authority_toctou=postvalidation_tree_changed"
    }
}

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
const head = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
execFileSync("git", ["switch", "--detach", "HEAD"], { stdio: "ignore" });
process.stdout.write(JSON.stringify({
  valid: true,
  evaluatedHead: head,
  inputDigest: "isolated-fixture",
  effectDecisions: {
    publication: { effect: "publication", allowed: true, disposition: "allowed", failedConstraintIds: [] }
  },
  failedConstraintIds: []
}) + "\n");
"@
    Write-Utf8NoBom -Path $cliPath -Value $stub

    Assert-ThrowsLike -Name "isolated-post-cli-head-detached" -Pattern "postvalidation_branch_changed" -ScriptBlock {
        Invoke-IsolatedCoreValidation -CliPath $cliPath
    }
}
finally {
    Set-Location $originalLocation
    if (Test-Path $runtimeRoot) { Remove-Item -Recurse -Force $runtimeRoot }
}

Write-Host "publicationToctouIsolatedFixture=passed"
