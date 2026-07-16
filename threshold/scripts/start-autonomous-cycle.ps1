[CmdletBinding()]
param(
    [string] $BaseRemote = "origin",
    [string] $BaseBranch = "main",
    [string] $OwnedRepo = "formatunitedandreas-code/spring-framework-petclinic",
    [string] $BacklogPath = "threshold/capability-backlog/approved-expansions.json",
    [int] $MaxCapabilityExpansions = 1,
    [switch] $SkipCapabilityExpansion,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function Invoke-Checked {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $FailureMessage
    )

    $output = @(& $FilePath @ArgumentList)
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $output) {
            Write-Host $line
        }
        throw $FailureMessage
    }
    return $output
}

function Assert-CleanWorktree {
    $status = @(& git status --porcelain)
    if ($status.Count -gt 0) {
        throw "Worktree is not clean."
    }
}

function Sync-MainLine {
    Assert-CleanWorktree
    Invoke-Checked -FilePath "git" -ArgumentList @("fetch", $BaseRemote) -FailureMessage "Failed to fetch $BaseRemote."
    Invoke-Checked -FilePath "git" -ArgumentList @("switch", $BaseBranch) -FailureMessage "Failed to switch to $BaseBranch."
    Invoke-Checked -FilePath "git" -ArgumentList @("pull", "--ff-only", $BaseRemote, $BaseBranch) -FailureMessage "Failed to fast-forward $BaseBranch from $BaseRemote/$BaseBranch."
    Assert-CleanWorktree
}

function Read-Backlog {
    if (-not (Test-Path $BacklogPath)) {
        throw "Capability backlog not found: $BacklogPath"
    }
    return Get-Content $BacklogPath -Raw | ConvertFrom-Json
}

function Get-NextApprovedExpansion {
    param([pscustomobject] $Backlog, [string] $Trigger)

    $entries = @($Backlog.approvedExpansions)
    foreach ($entry in $entries) {
        if ($entry.enabled -ne $true) { continue }
        if ([string]$entry.status -ne "ready") { continue }
        if (@($entry.triggerTerminalStates) -notcontains $Trigger) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$entry.applyScript)) { continue }
        if (-not @($entry.allowedChangedPaths).Count) { continue }
        return $entry
    }
    return $null
}

function Test-PathAgainstPattern {
    param([string] $Path, [string] $Pattern)

    $normalizedPath = ConvertTo-RepoPath $Path
    $normalizedPattern = ConvertTo-RepoPath $Pattern
    return [System.Management.Automation.WildcardPattern]::new($normalizedPattern, "IgnoreCase").IsMatch($normalizedPath)
}

function Assert-AllowedChangedPaths {
    param([string[]] $AllowedPatterns)

    $changedPaths = @(& git diff --name-only)
    $untrackedPaths = @(& git ls-files --others --exclude-standard)
    $allChangedPaths = @($changedPaths + $untrackedPaths | Select-Object -Unique)
    if (-not $allChangedPaths.Count) {
        throw "Capability expansion produced no file changes."
    }

    foreach ($path in $allChangedPaths) {
        $allowed = $false
        foreach ($pattern in $AllowedPatterns) {
            if (Test-PathAgainstPattern -Path $path -Pattern $pattern) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            throw "Capability expansion changed path outside allowedChangedPaths: $path"
        }
    }
}

function Invoke-ValidationCommand {
    param([string] $Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return
    }
    $scriptBlock = [scriptblock]::Create($Command)
    & $scriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "Validation command failed: $Command"
    }
}

function Invoke-CapabilityExpansion {
    param([pscustomobject] $Expansion)

    $applyScript = ConvertTo-RepoPath ([string]$Expansion.applyScript)
    if ($applyScript -notlike "threshold/scripts/*") {
        throw "Expansion applyScript must be under threshold/scripts/: $applyScript"
    }
    if (-not (Test-Path $applyScript)) {
        throw "Expansion applyScript not found: $applyScript"
    }

    $arguments = @()
    foreach ($argument in @($Expansion.arguments)) {
        $arguments += [string]$argument
    }

    Write-Host "capabilityExpansionStarted=true"
    Write-Host "capabilityExpansionId=$($Expansion.id)"
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $applyScript
    ) + $arguments -FailureMessage "Capability expansion apply script failed: $applyScript" | ForEach-Object { Write-Host $_ }

    Assert-AllowedChangedPaths -AllowedPatterns @($Expansion.allowedChangedPaths)
    Invoke-Checked -FilePath "git" -ArgumentList @("diff", "--check") -FailureMessage "git diff --check failed after capability expansion." | Out-Null
    foreach ($command in @($Expansion.validationCommands)) {
        Invoke-ValidationCommand -Command ([string]$command)
    }

    & git add -- @(& git diff --name-only)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage tracked capability expansion changes."
    }
    $untrackedPaths = @(& git ls-files --others --exclude-standard)
    if ($untrackedPaths.Count -gt 0) {
        & git add -- @untrackedPaths
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to stage untracked capability expansion changes."
        }
    }

    $commitMessage = [string]$Expansion.commitMessage
    if ([string]::IsNullOrWhiteSpace($commitMessage)) {
        $commitMessage = "feat: apply approved Threshold capability expansion"
    }
    & git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to commit capability expansion."
    }

    Write-Host "capabilityExpansionCommitted=true"
    Write-Host "capabilityExpansionCommit=$((& git rev-parse HEAD).Trim())"
}

function Invoke-OwnedPullRequestMerge {
    param([string] $Title, [string] $Body)

    $branch = (& git branch --show-current).Trim()
    Invoke-Checked -FilePath "git" -ArgumentList @("push", "-u", $BaseRemote, $branch) -FailureMessage "Failed to push $branch." | ForEach-Object { Write-Host $_ }

    $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-autonomous-cycle-pr.md"
    Set-Content -Path $bodyPath -Value $Body
    $prOutput = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "create",
        "--repo",
        $OwnedRepo,
        "--base",
        $BaseBranch,
        "--head",
        $branch,
        "--title",
        $Title,
        "--body-file",
        $bodyPath,
        "--draft"
    ) -FailureMessage "Failed to create capability expansion PR."
    $prUrl = ($prOutput | Select-Object -Last 1).Trim()
    $prMatch = [regex]::Match($prUrl, "/pull/(?<number>\d+)$")
    if (-not $prMatch.Success) {
        throw "Could not parse pull request number from '$prUrl'."
    }
    $prNumber = [int]$prMatch.Groups["number"].Value

    Invoke-Checked -FilePath "gh" -ArgumentList @("pr", "checks", "$prNumber", "--repo", $OwnedRepo, "--watch") -FailureMessage "Capability expansion PR checks failed." | ForEach-Object { Write-Host $_ }
    $metadata = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "view",
        "$prNumber",
        "--repo",
        $OwnedRepo,
        "--json",
        "state,isDraft,mergeable,mergeStateStatus"
    ) -FailureMessage "Failed to inspect capability expansion PR."
    $pullRequest = ($metadata -join "`n") | ConvertFrom-Json
    if ($pullRequest.state -ne "OPEN" -or $pullRequest.mergeable -ne "MERGEABLE" -or $pullRequest.mergeStateStatus -ne "CLEAN") {
        throw "Capability expansion PR is not cleanly mergeable."
    }

    Invoke-Checked -FilePath "gh" -ArgumentList @("pr", "ready", "$prNumber", "--repo", $OwnedRepo) -FailureMessage "Failed to mark capability expansion PR ready." | ForEach-Object { Write-Host $_ }
    Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "merge",
        "$prNumber",
        "--repo",
        $OwnedRepo,
        "--squash",
        "--subject",
        $Title,
        "--body",
        $Body
    ) -FailureMessage "Failed to merge capability expansion PR." | ForEach-Object { Write-Host $_ }

    Write-Host "capabilityExpansionPrMerged=true"
    Write-Host "capabilityExpansionPr=$prUrl"
}

function Invoke-WaveLifecycle {
    $output = @(
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/start-next-wave.ps1" -Phase FullLifecycle
    )
    foreach ($line in $output) {
        Write-Host $line
    }
    if ($LASTEXITCODE -ne 0) {
        throw "FullLifecycle wave failed."
    }
    return $output
}

Write-Host "autonomousCycle=started"
Write-Host "base=$BaseRemote/$BaseBranch"

if ($PlanOnly.IsPresent) {
    $backlog = Read-Backlog
    Write-Host "planOnly=true"
    Write-Host "approvedExpansionCount=$(@($backlog.approvedExpansions).Count)"
    Write-Host "heldExpansionCount=$(@($backlog.heldExpansions).Count)"
    Write-Host "autonomousCycle=completed"
    exit 0
}

Sync-MainLine
$waveOutput = Invoke-WaveLifecycle

if ($waveOutput -notcontains "ready_no_candidates_on_fresh_wave") {
    Sync-MainLine
    Write-Host "autonomousCycle=completed"
    Write-Host "cycleResult=wave_lifecycle_completed"
    exit 0
}

Write-Host "cycleResult=wave_reported_no_candidates"
if ($SkipCapabilityExpansion.IsPresent -or $MaxCapabilityExpansions -le 0) {
    Write-Host "capabilityExpansionSkipped=true"
    Sync-MainLine
    exit 0
}

$backlog = Read-Backlog
$expansion = Get-NextApprovedExpansion -Backlog $backlog -Trigger "ready_no_candidates_on_fresh_wave"
if (-not $expansion) {
    Write-Host "no_approved_capability_expansion_available"
    Sync-MainLine
    exit 0
}

Sync-MainLine
$expansionBranch = "threshold-capability-expansion-$($expansion.id)"
Invoke-Checked -FilePath "git" -ArgumentList @("switch", "-c", $expansionBranch, "$BaseRemote/$BaseBranch") -FailureMessage "Failed to create capability expansion branch." | ForEach-Object { Write-Host $_ }
Invoke-CapabilityExpansion -Expansion $expansion

$title = if ([string]::IsNullOrWhiteSpace([string]$expansion.prTitle)) {
    "Apply Threshold capability expansion $($expansion.id)"
} else {
    [string]$expansion.prTitle
}
$body = @"
## Summary
- apply approved Threshold capability expansion `$($expansion.id)`
- rerun autonomous lifecycle after merge

## Validation
- registry-defined validation commands passed
- git diff --check passed

## Non-claims
- owned repository only
- no upstream interaction
- no force push
- no release or deploy
- no public readiness/correctness/security/compliance claim
"@
Invoke-OwnedPullRequestMerge -Title $title -Body $body
Sync-MainLine
Invoke-WaveLifecycle | Out-Null
Sync-MainLine
Write-Host "autonomousCycle=completed"
Write-Host "cycleResult=capability_expansion_then_wave_completed"
