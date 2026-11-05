[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/test-fixture-directory.ps1")
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
$ownedFixture = New-ThresholdOwnedFixtureDirectory -Prefix "threshold-economy"
$fixtureRoot = $ownedFixture.Path
try {
    Set-Location $fixtureRoot
    Invoke-FixtureGit @("init", "--initial-branch=main")
    Invoke-FixtureGit @("config", "user.email", "fixture@example.invalid")
    Invoke-FixtureGit @("config", "user.name", "Threshold Fixture")
    Invoke-FixtureGit @("config", "core.longpaths", "true")
    New-Item -ItemType Directory -Path threshold/lease-state -Force | Out-Null
    "baseline" | Set-Content threshold/lease-state/current-run.json
    New-Item -ItemType Directory -Path threshold/runtime -Force | Out-Null
    "baseline runtime" | Set-Content threshold/runtime/original.txt
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

    "committed forbidden" | Set-Content threshold/lease-state/current-run.json
    Invoke-FixtureGit @("add", "threshold/lease-state/current-run.json")
    Invoke-FixtureGit @("commit", "-m", "fixture committed forbidden path")
    Invoke-FixtureGit @("restore", "--source=$base", "--staged", "--worktree", "--", "threshold/lease-state/current-run.json")
    Assert-EconomyStop "committed-forbidden-index-and-worktree-restored" "semantic_file_economy_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
    }
    Invoke-FixtureGit @("reset", "--hard", $base)

    Invoke-FixtureGit @("mv", "threshold/runtime/original.txt", "apparently-safe.txt")
    Assert-EconomyStop "forbidden-rename-source" "semantic_file_economy_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
    }
    Invoke-FixtureGit @("reset", "--hard", $base)
    $unusualNames = @("Grüße_日本語.txt")
    if ($env:OS -ne "Windows_NT") { $unusualNames += @("tab`tname.txt", "line`nname.txt") }
    foreach ($name in $unusualNames) {
        $path = "threshold/runtime/$name"
        "forbidden Unicode or control path" | Set-Content -LiteralPath $path
        Assert-EconomyStop "untracked-unusual-forbidden" "semantic_file_economy_breach" {
            Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
        }
        Invoke-FixtureGit @("add", "--", $path)
        Assert-EconomyStop "staged-unusual-forbidden" "semantic_file_economy_breach" {
            Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base
        }
        Invoke-FixtureGit @("reset", "--hard", $base)
    }

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
    @("{}", "{}", "{}", "{}") | Set-Content $evidence[0]
    Invoke-FixtureGit @("add", $evidence[0])
    Invoke-FixtureGit @("commit", "-m", "fixture committed oversized evidence")
    Invoke-FixtureGit @("restore", "--source=$base", "--staged", "--worktree", "--", "threshold/runs")
    if ((Get-ThresholdChangedLineCount -BaseRef $base -RunEvidence $evidence) -ne 6) {
        throw "committed_oversized_evidence_hidden_by_index_and_worktree_restoration"
    }
    Assert-EconomyStop "committed-oversized-index-and-worktree-restored" "changed_line_breach" {
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3
    }
    Invoke-FixtureGit @("reset", "--hard", $base)
    foreach ($name in $unusualNames) {
        $run = "threshold/runs/$name"
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        $unusualEvidence = @("twin-delta.json", "aggregate-receipt.json", "evidence-digests.json") |
            ForEach-Object { "$run/$_" }
        foreach ($path in $unusualEvidence) { "{}" | Set-Content -LiteralPath $path }
        Invoke-FixtureGit @("add", "--", $run)
        Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3 -RequireCompleteRunEvidence
        if ((Get-ThresholdChangedLineCount -BaseRef $base -RunEvidence $unusualEvidence) -ne 3) {
            throw "unusual_evidence_path_count_lost"
        }
        @("{}", "{}", "{}", "{}") | Set-Content -LiteralPath $unusualEvidence[0]
        Assert-EconomyStop "unusual-oversized" "changed_line_breach" {
            Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef $base -MaximumEvidenceChangedLines 3
        }
        Invoke-FixtureGit @("reset", "--hard", $base)
    }
    Write-Host "semanticFileEconomyFixtures=passed"
}
finally {
    Set-Location $originalLocation
    # This invocation created the exact absolute temp directory above.
    Remove-ThresholdOwnedFixtureDirectory -Fixture $ownedFixture
}
