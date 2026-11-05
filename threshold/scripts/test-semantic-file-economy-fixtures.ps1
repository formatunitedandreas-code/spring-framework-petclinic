[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

function Invoke-FixtureGit {
    param([string[]] $Arguments)
    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
}
function Assert-EconomyStop {
    param([string] $Name, [string] $Pattern, [scriptblock] $Action)
    try { & $Action }
    catch {
        if ($_.Exception.Message -match $Pattern) { Write-Host "expectedStop=$Name"; return }
        throw "Unexpected stop for ${Name}: $($_.Exception.Message)"
    }
    throw "Expected stop did not occur: $Name"
}

$originalLocation = Get-Location
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-economy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    Set-Location $fixtureRoot
    Invoke-FixtureGit @("init", "--initial-branch=main")
    Invoke-FixtureGit @("config", "user.email", "fixture@example.invalid")
    Invoke-FixtureGit @("config", "user.name", "Threshold Fixture")
    Invoke-FixtureGit @("config", "core.longpaths", "true")
    New-Item -ItemType Directory -Path threshold/lease-state -Force | Out-Null
    "baseline" | Set-Content threshold/lease-state/current-run.json
    "baseline" | Set-Content base.txt
    Invoke-FixtureGit @("add", ".")
    Invoke-FixtureGit @("commit", "-m", "fixture base")
    $base = (& git rev-parse HEAD).Trim()
    Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base

    "unstaged forbidden" | Set-Content threshold/lease-state/current-run.json
    Assert-EconomyStop "unstaged-forbidden" "semantic_file_economy_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
    }
    Invoke-FixtureGit @("add", "threshold/lease-state/current-run.json")
    # Restore the worktree alone. The forbidden staged version must still fail.
    "baseline" | Set-Content threshold/lease-state/current-run.json
    Assert-EconomyStop "staged-forbidden-worktree-reverted" "semantic_file_economy_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
    }
    Invoke-FixtureGit @("reset", "--hard", $base)

    $evidence = @("twin-delta.json", "aggregate-receipt.json", "evidence-digests.json") |
        ForEach-Object { "threshold/runs/fixture/$_" }
    New-Item -ItemType Directory threshold/runs/fixture -Force | Out-Null
    foreach ($path in $evidence) { "{}" | Set-Content $path }
    Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3 -RequireCompleteRunEvidence
    Invoke-FixtureGit @("add", "threshold/runs")
    Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3 -RequireCompleteRunEvidence
    if ((Get-ThresholdChangedLineCount -BaseRef $base -RunEvidence $evidence) -ne 3) {
        throw "same_index_and_worktree_evidence_double_counted"
    }
    @("{}", "{}", "{}", "{}") | Set-Content $evidence[0]
    Assert-EconomyStop "unstaged-oversized" "changed_line_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3
    }
    Invoke-FixtureGit @("add", $evidence[0])
    "{}" | Set-Content $evidence[0]
    Assert-EconomyStop "staged-oversized-worktree-small" "changed_line_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3
    }
    Invoke-FixtureGit @("add", $evidence[0])
    Invoke-FixtureGit @("commit", "-m", "fixture evidence")
    Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3 -RequireCompleteRunEvidence
    if ((Get-ThresholdChangedLineCount -BaseRef $base -RunEvidence $evidence) -ne 3) {
        throw "committed_and_worktree_evidence_double_counted"
    }
    Write-Host "semanticFileEconomyFixtures=passed"
}
finally {
    Set-Location $originalLocation
    # This invocation created the exact absolute temp directory above.
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
