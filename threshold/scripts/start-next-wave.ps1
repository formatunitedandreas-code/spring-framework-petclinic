[CmdletBinding()]
param(
    [string] $BaseRemote = "origin",
    [string] $BaseBranch = "main",
    [string] $BranchPrefix = "threshold-governed-refactor-demo-",
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $PocketPath = "threshold/candidate-pocket/current.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $LeaseName = "owned-autonomous-refactor-branch-wave-v0_automation",
    [int] $MaxCandidatesThisRun = 5,
    [int] $MaxCommitsThisRun = 5,
    [int] $MaxFilesPerCandidate = 1,
    [int] $MaxChangedLinesPerCandidate = 80,
    [int] $MaxRepairAttemptsPerCandidate = 1,
    [int] $MinAutoPatchableCandidates = 1,
    [string] $OwnedRepo = "formatunitedandreas-code/spring-framework-petclinic",
    [switch] $SkipPush,
    [switch] $SkipPullRequest,
    [switch] $SkipMerge
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
        if ($output) {
            foreach ($line in $output) {
                Write-Host $line
            }
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

function Get-WaveNumberFromBranch {
    param([string] $Branch)

    $match = [regex]::Match($Branch, [regex]::Escape($BranchPrefix) + "(?<number>\d+)$")
    if (-not $match.Success) {
        throw "Branch '$Branch' does not match prefix '$BranchPrefix'."
    }
    return [int]$match.Groups["number"].Value
}

function Get-NextWaveBranchName {
    $refs = @(& git for-each-ref --format="%(refname:short)" refs/heads refs/remotes/$BaseRemote)
    $maxNumber = 0
    foreach ($ref in $refs) {
        $trimmedRef = [string]$ref
        if ($trimmedRef.StartsWith("$BaseRemote/")) {
            $trimmedRef = $trimmedRef.Substring($BaseRemote.Length + 1)
        }
        $match = [regex]::Match($trimmedRef, "^" + [regex]::Escape($BranchPrefix) + "(?<number>\d+)$")
        if ($match.Success) {
            $number = [int]$match.Groups["number"].Value
            if ($number -gt $maxNumber) {
                $maxNumber = $number
            }
        }
    }
    return "$BranchPrefix$($maxNumber + 1)"
}

function Read-JsonFile {
    param([string] $Path)

    if (-not (Test-Path $Path)) {
        throw "JSON file not found: $Path"
    }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Commit-PathsIfNeeded {
    param(
        [string[]] $Paths,
        [string] $Message
    )

    & git add -- @Paths
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage paths for commit '$Message'."
    }

    & git diff --cached --quiet --exit-code
    if ($LASTEXITCODE -eq 0) {
        return $false
    }
    if ($LASTEXITCODE -ne 1) {
        throw "Failed to inspect staged changes for commit '$Message'."
    }

    & git commit -m $Message
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create commit '$Message'."
    }
    return $true
}

function Restore-GovernancePaths {
    $paths = @($LeasePath, $StatePath, $PocketPath)
    & git restore -- @paths
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restore governance files."
    }
}

function Update-CandidatePocket {
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\discover-candidates.ps1",
        "-LeasePath",
        $LeasePath,
        "-GatePath",
        $GatePath,
        "-PocketPath",
        $PocketPath,
        "-Limit",
        "100"
    ) -FailureMessage "Candidate discovery failed."
}

function Get-AutoPatchableCandidateCount {
    param([string] $Path)
    $pocket = Read-JsonFile -Path $Path
    return @($pocket.candidates | Where-Object { $_.autoPatchable -eq $true }).Count
}

function Sync-LeaseStateWrite {
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\sync-lease-state.ps1",
        "-LeasePath",
        $LeasePath,
        "-StatePath",
        $StatePath,
        "-Write"
    ) -FailureMessage "Lease-state sync write failed."
}

function Try-ExpandScopeForCandidateShortage {
    param([string] $Reason)

    $output = Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\expand-scope.ps1",
        "-LeasePath",
        $LeasePath,
        "-StatePath",
        $StatePath,
        "-GatePath",
        $GatePath,
        "-Reason",
        $Reason
    ) -FailureMessage "Scope expansion failed."

    foreach ($line in $output) {
        Write-Host $line
    }

    return ($output -contains "scopeExpansionApplied=true")
}

function Get-PullRequestMetadata {
    param([int] $Number)

    $json = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "api",
        "repos/$OwnedRepo/pulls/$Number",
        "-q",
        "{url: .html_url, state: .state, draft: .draft, merged: .merged, merged_at: .merged_at, mergeable: .mergeable, mergeable_state: .mergeable_state, merge_commit_sha: .merge_commit_sha, head_sha: .head.sha, base_ref: .base.ref}"
    ) -FailureMessage "Failed to query pull request #$Number."

    return ($json -join "`n" | ConvertFrom-Json)
}

function Assert-ReadyForMerge {
    param([pscustomobject] $PullRequest)

    if ($PullRequest.state -ne "open") {
        throw "Pull request is not open."
    }
    if ($PullRequest.draft -eq $true) {
        throw "Pull request is still draft."
    }
    if ($PullRequest.mergeable -ne $true) {
        throw "Pull request is not mergeable."
    }
    if ([string]$PullRequest.mergeable_state -ne "clean") {
        throw "Pull request mergeable_state is '$($PullRequest.mergeable_state)'."
    }
}

function New-PullRequestBody {
    param(
        [int] $WaveNumber,
        [pscustomobject] $State
    )

    return @"
## Summary
- start autonomous Threshold wave $WaveNumber from $BaseRemote/$BaseBranch
- execute bounded slices until terminal lease state
- record per-slice receipts and terminal lease evidence

## Validation
- `git diff --check`
- `$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd test`
- BUILD SUCCESS
- lease terminal state: $($State.terminalState)
- candidates processed: $($State.candidatesProcessed)
- commits created: $($State.commitsCreated)

## Non-claims
- no upstream interaction
- no force push
- no pom.xml or dependency change
- no src/test change
- no release or deploy
- no public readiness/correctness/security/compliance claim
"@
}

$governancePaths = @($LeasePath, $StatePath, $PocketPath)

Assert-CleanWorktree
Invoke-Checked -FilePath "git" -ArgumentList @("fetch", $BaseRemote) -FailureMessage "Failed to fetch $BaseRemote."

$branch = Get-NextWaveBranchName
Invoke-Checked -FilePath "git" -ArgumentList @("switch", "-c", $branch, "$BaseRemote/$BaseBranch") -FailureMessage "Failed to switch to new branch '$branch'."

Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    ".\threshold\scripts\start-lease.ps1",
    "-LeaseName",
    $LeaseName,
    "-MaxCandidatesThisRun",
    "$MaxCandidatesThisRun",
    "-MaxCommitsThisRun",
    "$MaxCommitsThisRun",
    "-MaxFilesPerCandidate",
    "$MaxFilesPerCandidate",
    "-MaxChangedLinesPerCandidate",
    "$MaxChangedLinesPerCandidate",
    "-MaxRepairAttemptsPerCandidate",
    "$MaxRepairAttemptsPerCandidate",
    "-DraftPrAllowed"
) -FailureMessage "Failed to start lease."

Update-CandidatePocket
$initialAutoPatchableCount = Get-AutoPatchableCandidateCount -Path $PocketPath
while ($initialAutoPatchableCount -lt $MinAutoPatchableCandidates) {
    if (-not (Try-ExpandScopeForCandidateShortage -Reason "fresh_wave_candidate_shortage")) {
        break
    }
    Update-CandidatePocket
    $initialAutoPatchableCount = Get-AutoPatchableCandidateCount -Path $PocketPath
}
if ($initialAutoPatchableCount -lt $MinAutoPatchableCandidates) {
    Restore-GovernancePaths
    Write-Host "ready_no_candidates_on_fresh_wave"
    Write-Host "branch=$branch"
    Write-Host "head=$((& git rev-parse HEAD).Trim())"
    Write-Host "autoPatchableCandidateCount=$initialAutoPatchableCount"
    Write-Host "minAutoPatchableCandidates=$MinAutoPatchableCandidates"
    exit 0
}

$waveNumber = Get-WaveNumberFromBranch -Branch $branch
[void](Commit-PathsIfNeeded -Paths $governancePaths -Message "Start Threshold wave $waveNumber candidate pocket")

while ($true) {
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\run-next-slice.ps1"
    ) -FailureMessage "run-next-slice failed."

    $state = Read-JsonFile -Path $StatePath
    if ($state.terminalState -eq "ready_no_candidates_verified") {
        Update-CandidatePocket
        $autoPatchableCandidateCount = Get-AutoPatchableCandidateCount -Path $PocketPath
        if ($state.remainingBudget.candidates -gt 0 -and
            $state.remainingBudget.commits -gt 0 -and
            $autoPatchableCandidateCount -lt $MinAutoPatchableCandidates -and
            (Try-ExpandScopeForCandidateShortage -Reason "mid_wave_candidate_shortage")) {
            Update-CandidatePocket
            [void](Commit-PathsIfNeeded -Paths $governancePaths -Message "Expand Threshold wave $waveNumber scope")
            continue
        }
        break
    }
    if ($state.terminalState -eq "budget_exhausted_verified") {
        break
    }

    Update-CandidatePocket
    [void](Commit-PathsIfNeeded -Paths @($PocketPath) -Message "Record Threshold wave $waveNumber updated candidate pocket")
}

Update-CandidatePocket
$state = Read-JsonFile -Path $StatePath
[void](Commit-PathsIfNeeded -Paths $governancePaths -Message "Record Threshold wave $waveNumber terminal state")

Assert-CleanWorktree
Invoke-Checked -FilePath "git" -ArgumentList @("diff", "--check") -FailureMessage "git diff --check failed."
Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    "`$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd test"
) -FailureMessage "Final Maven test failed."

if ($SkipPush.IsPresent) {
    Write-Host "start-next-wave completed without push"
    Write-Host "branch=$branch"
    Write-Host "head=$((& git rev-parse HEAD).Trim())"
    Write-Host "terminalState=$($state.terminalState)"
    exit 0
}

Invoke-Checked -FilePath "git" -ArgumentList @("push", $BaseRemote, $branch) -FailureMessage "Failed to push branch '$branch'."

if ($SkipPullRequest.IsPresent) {
    Write-Host "start-next-wave completed without pull request"
    Write-Host "branch=$branch"
    Write-Host "head=$((& git rev-parse HEAD).Trim())"
    Write-Host "terminalState=$($state.terminalState)"
    exit 0
}

$prTitle = "Refactor PetClinic autonomous wave $waveNumber"
$prBody = New-PullRequestBody -WaveNumber $waveNumber -State $state
$prCreateOutput = Invoke-Checked -FilePath "gh" -ArgumentList @(
    "pr",
    "create",
    "--repo",
    $OwnedRepo,
    "--base",
    $BaseBranch,
    "--head",
    $branch,
    "--title",
    $prTitle,
    "--body",
    $prBody
) -FailureMessage "Failed to create pull request."

$prUrl = ($prCreateOutput | Select-Object -Last 1).Trim()
$prMatch = [regex]::Match($prUrl, "/pull/(?<number>\d+)$")
if (-not $prMatch.Success) {
    throw "Could not parse pull request number from '$prUrl'."
}
$prNumber = [int]$prMatch.Groups["number"].Value

Invoke-Checked -FilePath "gh" -ArgumentList @(
    "pr",
    "checks",
    "$prNumber",
    "--repo",
    $OwnedRepo,
    "--watch"
) -FailureMessage "Pull request checks did not complete successfully for #$prNumber."

$pullRequest = Get-PullRequestMetadata -Number $prNumber
Assert-ReadyForMerge -PullRequest $pullRequest

if ($SkipMerge.IsPresent) {
    Write-Host "start-next-wave completed without merge"
    Write-Host "branch=$branch"
    Write-Host "pullRequest=$prUrl"
    Write-Host "terminalState=$($state.terminalState)"
    exit 0
}

$mergeBody = @"
PR #$prNumber
branch $branch
local validation: Maven test BUILD SUCCESS
CI: all visible checks passed
non-claims: no upstream interaction, no release, no deploy, no public readiness/correctness/security/compliance claim
"@

Invoke-Checked -FilePath "gh" -ArgumentList @(
    "pr",
    "merge",
    "$prNumber",
    "--repo",
    $OwnedRepo,
    "--squash",
    "--subject",
    $prTitle,
    "--body",
    $mergeBody
) -FailureMessage "Failed to merge pull request #$prNumber."

$mergedPullRequest = Get-PullRequestMetadata -Number $prNumber
if ($mergedPullRequest.merged -ne $true) {
    throw "Pull request #$prNumber did not reach merged state."
}

Write-Host "start-next-wave completed"
Write-Host "branch=$branch"
Write-Host "waveNumber=$waveNumber"
Write-Host "pullRequest=$($mergedPullRequest.url)"
Write-Host "mergeCommit=$($mergedPullRequest.merge_commit_sha)"
Write-Host "terminalState=$($state.terminalState)"
