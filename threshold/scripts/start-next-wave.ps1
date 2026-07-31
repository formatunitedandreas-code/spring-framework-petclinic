[CmdletBinding()]
param(
    [string] $BaseRemote = "origin",
    [string] $BaseBranch = "main",
    [string] $BranchPrefix = "threshold-governed-refactor-demo-",
    [string] $LeasePath = "",
    [string] $StatePath = "",
    [string] $PocketPath = "",
    [string] $GatePath = "",
    [string] $LeaseName = "owned-autonomous-refactor-branch-wave-v0_automation",
    [int] $MaxCandidatesThisRun = 5,
    [int] $MaxCommitsThisRun = 5,
    [int] $MaxFilesPerCandidate = 1,
    [int] $MaxChangedLinesPerCandidate = 80,
    [int] $MaxRepairAttemptsPerCandidate = 1,
    [int] $MinAutoPatchableCandidates = 1,
    [string] $OwnedRepo = "formatunitedandreas-code/spring-framework-petclinic",
    [ValidateSet(
        "LocalOnly",
        "PublishDraftPr",
        "VerifyPr",
        "VerifyPrUntilExternalReview",
        "MergeIfAuthorized",
        "FullLifecycleWithPolicyHold",
        "FullLifecycle"
    )]
    [string] $Phase = "FullLifecycle",
    [switch] $SkipPush,
    [switch] $SkipPullRequest,
    [switch] $SkipMerge,
    [switch] $PreferBatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/runtime-paths.ps1")
. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")

$SupportedGovernanceBranchPrefix = "threshold-governed-refactor-demo-"
if ($BranchPrefix -ne $SupportedGovernanceBranchPrefix) {
    throw "unsupported_branch_prefix_for_threshold_governance. branchPrefix=$BranchPrefix supportedPrefix=$SupportedGovernanceBranchPrefix"
}

$runtimePaths = Get-ThresholdRuntimePaths
if ([string]::IsNullOrWhiteSpace($LeasePath)) {
    $LeasePath = $runtimePaths.LeasePath
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = $runtimePaths.LeaseStatePath
}
if ([string]::IsNullOrWhiteSpace($PocketPath)) {
    $PocketPath = $runtimePaths.CandidatePocketPath
}
if ([string]::IsNullOrWhiteSpace($GatePath)) {
    $GatePath = $runtimePaths.AutoPatchableGatePath
}

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

function Read-LeaseLines {
    if (-not (Test-Path $LeasePath)) {
        throw "Lease file not found: $LeasePath"
    }
    return @(Get-Content $LeasePath)
}

function Get-LeaseIntScalarOrDefault {
    param(
        [string] $Name,
        [int] $DefaultValue
    )

    $leaseLines = Read-LeaseLines
    $match = $leaseLines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) {
        return $DefaultValue
    }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
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

function Invoke-PreProductDiscoveryPreparation {
    param(
        [string] $CandidatePocketPath,
        [int] $MinScore
    )

    $output = Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\prepare-discovery-evidence.ps1",
        "-CandidatePocketPath",
        $CandidatePocketPath,
        "-MinScore",
        "$MinScore"
    ) -FailureMessage "Pre-product discovery evidence preparation failed."

    foreach ($line in $output) {
        Write-Host $line
    }

    $evidencePaths = @(
        $output |
            Where-Object { [string]$_ -match "^discoveryEvidencePath=" } |
            ForEach-Object { ([string]$_).Substring("discoveryEvidencePath=".Length) }
    )
    if ($evidencePaths.Count -eq 0) {
        throw "Pre-product discovery evidence preparation produced no evidence artifacts."
    }

    return $evidencePaths
}

function Restore-GovernancePaths {
    $paths = @($LeasePath, $StatePath, $PocketPath)
    & git restore -- @paths
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restore governance files."
    }
}

function Restore-PreWaveBranch {
    param(
        [string] $PreviousBranch,
        [string] $WaveBranch
    )

    if ([string]::IsNullOrWhiteSpace($PreviousBranch) -or $PreviousBranch -eq $WaveBranch) {
        return
    }

    Invoke-Checked -FilePath "git" -ArgumentList @("switch", $PreviousBranch) -FailureMessage "Failed to restore previous branch '$PreviousBranch'."

    & git branch -D $WaveBranch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete transient wave branch '$WaveBranch'."
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

function Set-PreProductDiscoverySourceHead {
    param(
        [string] $CandidatePocketPath,
        [string] $DiscoverySourceHead
    )

    if ([string]::IsNullOrWhiteSpace($DiscoverySourceHead)) {
        throw "Discovery source head is required for pre-product evidence binding."
    }
    if (-not (Test-Path $CandidatePocketPath)) {
        throw "Candidate pocket not found for pre-product evidence binding: $CandidatePocketPath"
    }

    $pocket = Read-JsonFile -Path $CandidatePocketPath
    Set-JsonProperty -Object $pocket -Name "preProductDiscoverySourceHead" -Value $DiscoverySourceHead
    Set-JsonProperty -Object $pocket -Name "preProductDiscoveryEvidencePolicy" -Value "CandidateDiscoveryEvidence is materialized from this source head before product slice commits and remains the lookup key across later pocket refreshes."
    $pocket | ConvertTo-Json -Depth 12 | Set-Content $CandidatePocketPath
}

function Get-AutoPatchableCandidateCount {
    param([string] $Path)
    $pocket = Read-JsonFile -Path $Path
    $minScore = Get-LeaseIntScalarOrDefault -Name "minScore" -DefaultValue 70
    return @($pocket.candidates | Where-Object { $_.autoPatchable -eq $true -and [int]$_.score -ge $minScore }).Count
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

function Set-JsonProperty {
    param(
        [pscustomobject] $Object,
        [string] $Name,
        [object] $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Mark-TerminalEvidenceSourceHead {
    $sourceHead = (& git rev-parse HEAD).Trim()

    $state = Read-JsonFile -Path $StatePath
    Set-JsonProperty -Object $state -Name "currentHeadRole" -Value "sourceHead"
    Set-JsonProperty -Object $state -Name "terminalEvidenceHead" -Value $sourceHead
    Set-JsonProperty -Object $state -Name "terminalEvidencePolicy" -Value "terminal evidence is generated from the last governed source/evidence head before the terminal governance commit"
    Set-JsonProperty -Object $state -Name "terminalEvidenceMarkedAt" -Value (Get-Date).ToUniversalTime().ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $StatePath

    $pocket = Read-JsonFile -Path $PocketPath
    Set-JsonProperty -Object $pocket -Name "generatedFromHeadRole" -Value "sourceHead"
    Set-JsonProperty -Object $pocket -Name "terminalEvidenceHead" -Value $sourceHead
    Set-JsonProperty -Object $pocket -Name "terminalEvidencePolicy" -Value "candidate pocket is generated from the last governed source/evidence head before the terminal governance commit"
    $pocket | ConvertTo-Json -Depth 12 | Set-Content $PocketPath
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

function Invoke-BatchIfAvailable {
    if (-not $PreferBatch.IsPresent) {
        return $false
    }

    $output = Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\threshold\scripts\run-next-batch.ps1",
        "-CandidatePocketPath",
        $PocketPath,
        "-PrBaseHead",
        $script:CurrentWaveEvidenceHead,
        "-RequirePreProductDiscoveryEvidence"
    ) -FailureMessage "run-next-batch failed."

    foreach ($line in $output) {
        Write-Host $line
    }

    return @($output | Where-Object { [string]$_ -eq "Threshold batch completed" }).Count -gt 0
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

function Get-PullRequestReviewDecision {
    param([int] $Number)

    $json = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "view",
        "$Number",
        "--repo",
        $OwnedRepo,
        "--json",
        "reviewDecision"
    ) -FailureMessage "Failed to query pull request review decision for #$Number."

    $metadata = ($json -join "`n" | ConvertFrom-Json)
    return [string]$metadata.reviewDecision
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

function Assert-RemoteBaseMatchesMergeCommit {
    param(
        [pscustomobject] $MergedPullRequest,
        [string] $ExpectedBaseBranch = $BaseBranch
    )

    $mergeCommit = [string]$MergedPullRequest.merge_commit_sha
    if ([string]::IsNullOrWhiteSpace($mergeCommit)) {
        throw "Merged pull request did not report merge_commit_sha."
    }

    Invoke-Checked -FilePath "git" -ArgumentList @(
        "fetch",
        $BaseRemote
    ) -FailureMessage "Failed to refresh $BaseRemote after merge."

    $remoteBase = (Invoke-Checked -FilePath "git" -ArgumentList @(
        "rev-parse",
        "$BaseRemote/$ExpectedBaseBranch"
    ) -FailureMessage "Failed to resolve $BaseRemote/$ExpectedBaseBranch after merge.") -join "`n"
    $remoteBase = $remoteBase.Trim()

    if ($remoteBase -ne $mergeCommit) {
        throw "remote_base_stale_after_merge. base=$BaseRemote/$ExpectedBaseBranch expected=$mergeCommit actual=$remoteBase"
    }

    Write-Host "postMergeRemoteRefresh=passed"
    Write-Host "remoteBase=$BaseRemote/$ExpectedBaseBranch"
    Write-Host "remoteHead=$remoteBase"
}

function New-GovernedEvidenceBasePromotionBody {
    param(
        [pscustomobject] $Wave,
        [pscustomobject] $MergedPullRequest
    )

    $mergeCommit = [string]$MergedPullRequest.merge_commit_sha
    if ([string]::IsNullOrWhiteSpace($mergeCommit)) {
        throw "Merged pull request did not report merge_commit_sha for governed evidence-base promotion."
    }

    return @"
## Summary
- promote governed Threshold wave $($Wave.WaveNumber) evidence-base result to $BaseRemote/$BaseBranch
- preserve the merged product/evidence head as the exact PR review object
- reconcile configured base only through this separate promotion PR

## Bound Source
- product pull request: $($MergedPullRequest.url)
- product/evidence merge commit: `$mergeCommit`
- evidence base branch: `$($Wave.PullRequestBaseBranch)`
- configured base: `$BaseRemote/$BaseBranch`

## Non-claims
- no direct configured-base push
- no force push
- no dependency change
- no release or deploy
"@
}

function Invoke-GovernedEvidenceBasePromotion {
    param(
        [pscustomobject] $Wave,
        [pscustomobject] $MergedPullRequest
    )

    $mergeCommit = [string]$MergedPullRequest.merge_commit_sha
    if ([string]::IsNullOrWhiteSpace($mergeCommit)) {
        throw "Merged pull request did not report merge_commit_sha for governed evidence-base promotion."
    }

    Invoke-Checked -FilePath "git" -ArgumentList @("fetch", $BaseRemote) -FailureMessage "Failed to refresh $BaseRemote before governed evidence-base promotion."

    & git merge-base --is-ancestor "$BaseRemote/$BaseBranch" $mergeCommit
    if ($LASTEXITCODE -ne 0) {
        throw "governed_evidence_base_promotion_not_descendant_of_configured_base. configuredBase=$BaseRemote/$BaseBranch productMergeCommit=$mergeCommit"
    }

    $safeBaseBranch = ($BaseBranch -replace "[^A-Za-z0-9._-]", "-")
    $promotionBranch = "$($Wave.EvidenceBranch)-promote-to-$safeBaseBranch"
    Invoke-Checked -FilePath "git" -ArgumentList @("branch", "-f", $promotionBranch, $mergeCommit) -FailureMessage "Failed to create governed evidence-base promotion branch '$promotionBranch'."
    Invoke-Checked -FilePath "git" -ArgumentList @("push", $BaseRemote, "$promotionBranch`:refs/heads/$promotionBranch") -FailureMessage "Failed to push governed evidence-base promotion branch '$promotionBranch'."

    $promotionTitle = "Promote Threshold wave $($Wave.WaveNumber) evidence base"
    $promotionBody = New-GovernedEvidenceBasePromotionBody -Wave $Wave -MergedPullRequest $MergedPullRequest
    $promotionPrOutput = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "create",
        "--repo",
        $OwnedRepo,
        "--base",
        $BaseBranch,
        "--head",
        $promotionBranch,
        "--title",
        $promotionTitle,
        "--body",
        $promotionBody
    ) -FailureMessage "Failed to create governed evidence-base promotion pull request."

    $promotionPrUrl = ($promotionPrOutput | Select-Object -Last 1).Trim()
    $promotionPrMatch = [regex]::Match($promotionPrUrl, "/pull/(?<number>\d+)$")
    if (-not $promotionPrMatch.Success) {
        throw "Could not parse governed evidence-base promotion pull request number from '$promotionPrUrl'."
    }
    $promotionPr = [pscustomobject]@{
        Number = [int]$promotionPrMatch.Groups["number"].Value
        Url = $promotionPrUrl
        Title = $promotionTitle
        Branch = $promotionBranch
        Head = $mergeCommit
    }

    [void](@(Invoke-PullRequestVerification -PullRequest $promotionPr) | Select-Object -Last 1)
    $mergedPromotionPr = @(Invoke-AuthorizedMerge -Wave ([pscustomobject]@{
        Branch = $promotionBranch
        PullRequestBaseBranch = $BaseBranch
        EvidenceBranch = $Wave.EvidenceBranch
        WaveNumber = $Wave.WaveNumber
    }) -PullRequest $promotionPr) | Select-Object -Last 1

    Assert-RemoteBaseMatchesMergeCommit -MergedPullRequest $mergedPromotionPr -ExpectedBaseBranch $BaseBranch
    Write-Host "governedEvidenceBasePromotion=merged"
    Write-Host "governedEvidenceBasePromotionPr=$($promotionPr.Url)"
    return $mergedPromotionPr
}

function Assert-PullRequestBaseHasThresholdGovernanceTrigger {
    param([string] $PullRequestBaseBranch)

    if ($PullRequestBaseBranch -eq $BaseBranch) {
        return
    }
    if ($PullRequestBaseBranch -match "^threshold-governed-refactor-demo-\d+-discovery-base$") {
        return
    }

    throw "Pull request base '$PullRequestBaseBranch' is not covered by the Threshold governance workflow trigger."
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

function Invoke-LocalWave {
    $governancePaths = @($LeasePath, $StatePath, $PocketPath)

    Assert-CleanWorktree
    Invoke-Checked -FilePath "git" -ArgumentList @("fetch", $BaseRemote) -FailureMessage "Failed to fetch $BaseRemote."

    $startingBranch = (& git branch --show-current).Trim()
    $branch = Get-NextWaveBranchName
    $evidenceBranch = "$branch-discovery-base"
    Invoke-Checked -FilePath "git" -ArgumentList @("switch", "-c", $evidenceBranch, "$BaseRemote/$BaseBranch") -FailureMessage "Failed to switch to new discovery evidence branch '$evidenceBranch'."
    $discoverySourceHead = (& git rev-parse HEAD).Trim()

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
        "-BranchName",
        $branch,
        "-BaseRef",
        "$BaseRemote/$evidenceBranch",
        "-DraftPrAllowed"
    ) -FailureMessage "Failed to start lease."

    Update-CandidatePocket
    Set-PreProductDiscoverySourceHead -CandidatePocketPath $PocketPath -DiscoverySourceHead $discoverySourceHead
    $initialAutoPatchableCount = Get-AutoPatchableCandidateCount -Path $PocketPath
    while ($initialAutoPatchableCount -lt $MinAutoPatchableCandidates) {
        if (-not (Try-ExpandScopeForCandidateShortage -Reason "fresh_wave_candidate_shortage")) {
            break
        }
        Update-CandidatePocket
        Set-PreProductDiscoverySourceHead -CandidatePocketPath $PocketPath -DiscoverySourceHead $discoverySourceHead
        $initialAutoPatchableCount = Get-AutoPatchableCandidateCount -Path $PocketPath
    }
    if ($initialAutoPatchableCount -lt $MinAutoPatchableCandidates) {
        Restore-GovernancePaths
        Restore-PreWaveBranch -PreviousBranch $startingBranch -WaveBranch $evidenceBranch
        Write-Host "ready_no_candidates_on_fresh_wave"
        Write-Host "branch=$branch"
        Write-Host "currentBranch=$((& git branch --show-current).Trim())"
        Write-Host "head=$((& git rev-parse HEAD).Trim())"
        Write-Host "autoPatchableCandidateCount=$initialAutoPatchableCount"
        Write-Host "minAutoPatchableCandidates=$MinAutoPatchableCandidates"
        exit 0
    }

    $waveNumber = Get-WaveNumberFromBranch -Branch $branch
    $minScore = Get-LeaseIntScalarOrDefault -Name "minScore" -DefaultValue 70
    $evidencePaths = Invoke-PreProductDiscoveryPreparation -CandidatePocketPath $PocketPath -MinScore $minScore
    [void](Commit-PathsIfNeeded -Paths ($governancePaths + $evidencePaths) -Message "Prepare Threshold wave $waveNumber discovery evidence")
    $evidenceHead = (& git rev-parse HEAD).Trim()
    $script:CurrentWaveEvidenceHead = $evidenceHead
    Invoke-Checked -FilePath "git" -ArgumentList @("switch", "-c", $branch, $evidenceHead) -FailureMessage "Failed to switch to product branch '$branch'."

    while ($true) {
        $batchCompleted = Invoke-BatchIfAvailable
        if (-not $batchCompleted) {
            Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ".\threshold\scripts\run-next-slice.ps1",
                "-PrBaseHead",
                $evidenceHead,
                "-MinScore",
                "$(Get-LeaseIntScalarOrDefault -Name "minScore" -DefaultValue 70)"
            ) -FailureMessage "run-next-slice failed."
        }

        $state = Read-JsonFile -Path $StatePath
        if ($state.terminalState -eq "ready_no_candidates_verified") {
            Update-CandidatePocket
            $autoPatchableCandidateCount = Get-AutoPatchableCandidateCount -Path $PocketPath
            if ($state.remainingBudget.candidates -gt 0 -and
                $state.remainingBudget.commits -gt 0 -and
                $autoPatchableCandidateCount -lt $MinAutoPatchableCandidates) {
                Write-Host "midWaveScopeExpansionBlocked=true"
                Write-Host "midWaveScopeExpansionPolicy=scope expansion after product branch start would create discovery evidence inside the product PR"
            }
            break
        }
        if ($state.terminalState -eq "budget_exhausted_verified") {
            break
        }

        Write-Host "candidatePocketRefreshBlocked=true"
        Write-Host "candidatePocketRefreshPolicy=product slices must consume the pre-product evidence-bearing candidate pocket"
    }

    Update-CandidatePocket
    Set-PreProductDiscoverySourceHead -CandidatePocketPath $PocketPath -DiscoverySourceHead $discoverySourceHead
    Mark-TerminalEvidenceSourceHead
    $state = Read-JsonFile -Path $StatePath
    [void](Commit-PathsIfNeeded -Paths $governancePaths -Message "Record Threshold wave $waveNumber terminal state")

    return [pscustomobject]@{
        Branch = $branch
        EvidenceBranch = $evidenceBranch
        PullRequestBaseBranch = $evidenceBranch
        PullRequestBaseGovernanceTriggered = $true
        EvidenceHead = $evidenceHead
        WaveNumber = $waveNumber
        State = $state
    }
}

function Invoke-LocalWaveValidation {
    Assert-CleanWorktree
    Invoke-Checked -FilePath "git" -ArgumentList @("diff", "--check") -FailureMessage "git diff --check failed."
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        "`$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd test"
    ) -FailureMessage "Final Maven test failed."
}

function Invoke-PullRequestPublish {
    param([pscustomobject] $Wave)

    $leaseLines = Read-LeaseLines
    Assert-ThresholdActionAllowed -LeaseLines $leaseLines -LeasePath $LeasePath -Action "pr"

    Invoke-Checked -FilePath "git" -ArgumentList @("push", $BaseRemote, $Wave.EvidenceBranch) -FailureMessage "Failed to push discovery evidence branch '$($Wave.EvidenceBranch)'."
    Invoke-Checked -FilePath "git" -ArgumentList @("push", $BaseRemote, $Wave.Branch) -FailureMessage "Failed to push branch '$($Wave.Branch)'."

    if ($SkipPullRequest.IsPresent) {
        Write-Host "start-next-wave completed without pull request"
        Write-Host "branch=$($Wave.Branch)"
        Write-Host "head=$((& git rev-parse HEAD).Trim())"
        Write-Host "terminalState=$($Wave.State.terminalState)"
        exit 0
    }

    $prTitle = "Refactor PetClinic autonomous wave $($Wave.WaveNumber)"
    $prBody = New-PullRequestBody -WaveNumber $Wave.WaveNumber -State $Wave.State
    Assert-PullRequestBaseHasThresholdGovernanceTrigger -PullRequestBaseBranch $Wave.PullRequestBaseBranch
    $prCreateOutput = Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "create",
        "--repo",
        $OwnedRepo,
        "--base",
        $Wave.PullRequestBaseBranch,
        "--head",
        $Wave.Branch,
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

    return [pscustomobject]@{
        Number = $prNumber
        Url = $prUrl
        Title = $prTitle
    }
}

function Invoke-PullRequestVerification {
    param([pscustomobject] $PullRequest)

    Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "checks",
        "$($PullRequest.Number)",
        "--repo",
        $OwnedRepo,
        "--watch"
    ) -FailureMessage "Pull request checks did not complete successfully for #$($PullRequest.Number)."

    $pullRequestMetadata = Get-PullRequestMetadata -Number $PullRequest.Number
    Assert-ReadyForMerge -PullRequest $pullRequestMetadata
    return $pullRequestMetadata
}

function Invoke-AuthorizedMerge {
    param(
        [pscustomobject] $Wave,
        [pscustomobject] $PullRequest
    )

    $leaseLines = Read-LeaseLines
    Assert-ThresholdActionAllowed -LeaseLines $leaseLines -LeasePath $LeasePath -Action "merge"

    $mergeBody = @"
PR #$($PullRequest.Number)
branch $($Wave.Branch)
local validation: Maven test BUILD SUCCESS
CI: all visible checks passed
non-claims: no upstream interaction, no release, no deploy, no public readiness/correctness/security/compliance claim
"@

    Invoke-Checked -FilePath "gh" -ArgumentList @(
        "pr",
        "merge",
        "$($PullRequest.Number)",
        "--repo",
        $OwnedRepo,
        "--squash",
        "--subject",
        $PullRequest.Title,
        "--body",
        $mergeBody
    ) -FailureMessage "Failed to merge pull request #$($PullRequest.Number)."

    $mergedPullRequest = Get-PullRequestMetadata -Number $PullRequest.Number
    if ($mergedPullRequest.merged -ne $true) {
        throw "Pull request #$($PullRequest.Number) did not reach merged state."
    }

    Assert-RemoteBaseMatchesMergeCommit -MergedPullRequest $mergedPullRequest -ExpectedBaseBranch $Wave.PullRequestBaseBranch
    if ($Wave.PullRequestBaseBranch -ne $BaseBranch) {
        [void](@(Invoke-GovernedEvidenceBasePromotion -Wave $Wave -MergedPullRequest $mergedPullRequest) | Select-Object -Last 1)
    }
    return $mergedPullRequest
}

$wave = @(Invoke-LocalWave) | Select-Object -Last 1
Invoke-LocalWaveValidation

if ($SkipPush.IsPresent -or $Phase -eq "LocalOnly") {
    Write-Host "start-next-wave completed without push"
    Write-Host "phase=$Phase"
    Write-Host "branch=$($wave.Branch)"
    Write-Host "head=$((& git rev-parse HEAD).Trim())"
    Write-Host "terminalState=$($wave.State.terminalState)"
    exit 0
}

$pullRequest = @(Invoke-PullRequestPublish -Wave $wave) | Select-Object -Last 1

if ($Phase -eq "PublishDraftPr") {
    Write-Host "start-next-wave completed after pull request publication"
    Write-Host "phase=$Phase"
    Write-Host "branch=$($wave.Branch)"
    Write-Host "pullRequest=$($pullRequest.Url)"
    Write-Host "terminalState=$($wave.State.terminalState)"
    exit 0
}

$pullRequestMetadata = @(Invoke-PullRequestVerification -PullRequest $pullRequest) | Select-Object -Last 1
$reviewDecision = Get-PullRequestReviewDecision -Number $pullRequest.Number

if ($SkipMerge.IsPresent -or $Phase -eq "VerifyPr" -or $Phase -eq "VerifyPrUntilExternalReview") {
    Write-Host "start-next-wave completed without merge"
    Write-Host "phase=$Phase"
    Write-Host "branch=$($wave.Branch)"
    Write-Host "pullRequest=$($pullRequest.Url)"
    Write-Host "mergeableState=$($pullRequestMetadata.mergeable_state)"
    Write-Host "reviewDecision=$reviewDecision"
    if ($Phase -eq "VerifyPrUntilExternalReview" -and $reviewDecision -eq "REVIEW_REQUIRED") {
        Write-Host "policyHold=external_review_required"
    }
    Write-Host "terminalState=$($wave.State.terminalState)"
    exit 0
}

if ($Phase -eq "FullLifecycleWithPolicyHold") {
    Write-Host "start-next-wave completed at policy hold"
    Write-Host "phase=$Phase"
    Write-Host "branch=$($wave.Branch)"
    Write-Host "pullRequest=$($pullRequest.Url)"
    Write-Host "mergeableState=$($pullRequestMetadata.mergeable_state)"
    Write-Host "reviewDecision=$reviewDecision"
    Write-Host "policyHold=merge_requires_explicit_authority_or_external_review"
    Write-Host "terminalState=$($wave.State.terminalState)"
    exit 0
}

$mergedPullRequest = @(Invoke-AuthorizedMerge -Wave $wave -PullRequest $pullRequest) | Select-Object -Last 1

Write-Host "start-next-wave completed"
Write-Host "branch=$($wave.Branch)"
Write-Host "waveNumber=$($wave.WaveNumber)"
Write-Host "pullRequest=$($mergedPullRequest.url)"
Write-Host "mergeCommit=$($mergedPullRequest.merge_commit_sha)"
Write-Host "terminalState=$($wave.State.terminalState)"
Write-Host "ready_for_next_wave=true"
