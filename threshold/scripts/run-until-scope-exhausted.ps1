[CmdletBinding()]
param(
    [string] $LeasePath = "",
    [string] $StatePath = "",
    [string] $PocketPath = "",
    [string] $GatePath = "",
    [string] $LeaseName = "owned-autonomous-refactor-scope-drain-v0_automation",
    [int] $MaxSegments = 20,
    [int] $MaxCandidatesPerSegment = 5,
    [int] $MaxCommitsPerSegment = 5,
    [int] $MaxFilesPerCandidate = 1,
    [int] $MaxChangedLinesPerCandidate = 80,
    [int] $MaxRepairAttemptsPerCandidate = 1,
    [int] $MinAutoPatchableCandidates = 1,
    [int] $MinScore = 70,
    [switch] $SkipMavenTest,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/runtime-paths.ps1")

$runtimePaths = Get-ThresholdRuntimePaths
if ([string]::IsNullOrWhiteSpace($LeasePath)) { $LeasePath = $runtimePaths.LeasePath }
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $runtimePaths.LeaseStatePath }
if ([string]::IsNullOrWhiteSpace($PocketPath)) { $PocketPath = $runtimePaths.CandidatePocketPath }
if ([string]::IsNullOrWhiteSpace($GatePath)) { $GatePath = $runtimePaths.AutoPatchableGatePath }

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
        foreach ($line in $output) { Write-Host $line }
        throw $FailureMessage
    }
    return $output
}

function Read-JsonFile {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "JSON file not found: $Path" }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Assert-CleanWorktree {
    $status = @(& git status --porcelain)
    if ($status.Count -gt 0) {
        throw "Worktree is not clean. Scope drain requires a clean start for every segment."
    }
}

function Commit-PathsIfNeeded {
    param(
        [string[]] $Paths,
        [string] $Message
    )

    $existingPaths = @($Paths | Where-Object { Test-Path $_ } | ForEach-Object { ConvertTo-RepoPath $_ } | Select-Object -Unique)
    if (-not $existingPaths) { return $false }

    & git add -- @existingPaths
    if ($LASTEXITCODE -ne 0) { throw "Failed to stage paths for commit '$Message'." }

    & git diff --cached --quiet --exit-code
    if ($LASTEXITCODE -eq 0) { return $false }
    if ($LASTEXITCODE -ne 1) { throw "Failed to inspect staged changes for commit '$Message'." }

    & git commit -m $Message
    if ($LASTEXITCODE -ne 0) { throw "Failed to create commit '$Message'." }
    return $true
}

function Get-AutoPatchableCandidateCount {
    param([string] $Path)
    $pocket = Read-JsonFile -Path $Path
    return @($pocket.candidates | Where-Object { $_.autoPatchable -eq $true -and [int]$_.score -ge $MinScore }).Count
}

function Update-CandidatePocket {
    param([int] $Limit = 100)

    $output = Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "threshold/scripts/discover-candidates.ps1",
        "-LeasePath",
        $LeasePath,
        "-GatePath",
        $GatePath,
        "-PocketPath",
        $PocketPath,
        "-Limit",
        "$Limit"
    ) -FailureMessage "Candidate discovery failed."
    foreach ($line in $output) { Write-Host $line }
}

function Try-ExpandScope {
    param([string] $Reason)

    $output = Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "threshold/scripts/expand-scope.ps1",
        "-LeasePath",
        $LeasePath,
        "-StatePath",
        $StatePath,
        "-GatePath",
        $GatePath,
        "-Reason",
        $Reason
    ) -FailureMessage "Scope expansion failed."
    foreach ($line in $output) { Write-Host $line }
    return ($output -contains "scopeExpansionApplied=true")
}

function Start-DrainSegment {
    param([int] $Segment)

    Invoke-Checked -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "threshold/scripts/start-lease.ps1",
        "-LeasePath",
        $LeasePath,
        "-StatePath",
        $StatePath,
        "-LeaseName",
        $LeaseName,
        "-MaxCandidatesThisRun",
        "$MaxCandidatesPerSegment",
        "-MaxCommitsThisRun",
        "$MaxCommitsPerSegment",
        "-MaxFilesPerCandidate",
        "$MaxFilesPerCandidate",
        "-MaxChangedLinesPerCandidate",
        "$MaxChangedLinesPerCandidate",
        "-MaxRepairAttemptsPerCandidate",
        "$MaxRepairAttemptsPerCandidate"
    ) -FailureMessage "Failed to start scope-drain lease segment." | ForEach-Object { Write-Host $_ }

    Update-CandidatePocket
    $autoPatchableCandidateCount = Get-AutoPatchableCandidateCount -Path $PocketPath
    while ($autoPatchableCandidateCount -lt $MinAutoPatchableCandidates) {
        if (-not (Try-ExpandScope -Reason "scope_drain_fresh_segment_candidate_shortage")) {
            break
        }
        Update-CandidatePocket
        $autoPatchableCandidateCount = Get-AutoPatchableCandidateCount -Path $PocketPath
    }

    [void](Commit-PathsIfNeeded -Paths @($LeasePath, $StatePath, $PocketPath) -Message "Start Threshold scope drain segment $Segment")
    return $autoPatchableCandidateCount
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

function Set-ScopeDrainTerminalState {
    param(
        [string] $TerminalState,
        [string] $Reason
    )

    $state = Read-JsonFile -Path $StatePath
    Set-JsonProperty -Object $state -Name "scopeDrainTerminalState" -Value $TerminalState
    Set-JsonProperty -Object $state -Name "scopeDrainTerminalReason" -Value $Reason
    Set-JsonProperty -Object $state -Name "scopeDrainCompletedAt" -Value (Get-Date).ToUniversalTime().ToString("o")
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $StatePath
}

function Invoke-RunNextSlice {
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "threshold/scripts/run-next-slice.ps1",
        "-LeasePath",
        $LeasePath,
        "-StatePath",
        $StatePath,
        "-PocketPath",
        $PocketPath,
        "-GatePath",
        $GatePath,
        "-MinScore",
        "$MinScore"
    )
    if ($SkipMavenTest.IsPresent) { $args += "-SkipMavenTest" }
    Invoke-Checked -FilePath "powershell.exe" -ArgumentList $args -FailureMessage "run-next-slice failed." | ForEach-Object { Write-Host $_ }
}

if ($MaxSegments -lt 1) { throw "MaxSegments must be at least 1." }
if ($MaxCandidatesPerSegment -lt 1) { throw "MaxCandidatesPerSegment must be at least 1." }
if ($MaxCommitsPerSegment -lt 1) { throw "MaxCommitsPerSegment must be at least 1." }

Write-Host "scopeDrain=started"
Write-Host "branch=$((& git branch --show-current).Trim())"
Write-Host "head=$((& git rev-parse HEAD).Trim())"
Write-Host "maxSegments=$MaxSegments"

if ($PlanOnly.IsPresent) {
    Write-Host "planOnly=true"
    Write-Host "leasePath=$(ConvertTo-RepoPath $LeasePath)"
    Write-Host "statePath=$(ConvertTo-RepoPath $StatePath)"
    Write-Host "pocketPath=$(ConvertTo-RepoPath $PocketPath)"
    Write-Host "gatePath=$(ConvertTo-RepoPath $GatePath)"
    Write-Host "scopeDrain=completed"
    exit 0
}

$segment = 0
while ($segment -lt $MaxSegments) {
    $segment++
    Assert-CleanWorktree
    Write-Host "scopeDrainSegment=$segment"

    $initialAutoPatchableCount = Start-DrainSegment -Segment $segment
    if ($initialAutoPatchableCount -lt $MinAutoPatchableCandidates) {
        Mark-TerminalEvidenceSourceHead
        Set-ScopeDrainTerminalState -TerminalState "scope_exhausted_verified" -Reason "fresh segment discovery found no auto-patchable candidates after all available scope expansion tiers"
        [void](Commit-PathsIfNeeded -Paths @($LeasePath, $StatePath, $PocketPath) -Message "Record Threshold scope drain exhausted state")
        Write-Host "scopeDrainTerminalState=scope_exhausted_verified"
        Write-Host "scopeDrainSegmentsRun=$segment"
        Write-Host "scopeDrain=completed"
        exit 0
    }

    while ($true) {
        Invoke-RunNextSlice
        $state = Read-JsonFile -Path $StatePath
        if ($state.terminalState -eq "ready_no_candidates_verified") {
            Update-CandidatePocket
            $autoPatchableCandidateCount = Get-AutoPatchableCandidateCount -Path $PocketPath
            if ($state.remainingBudget.candidates -gt 0 -and
                $state.remainingBudget.commits -gt 0 -and
                $autoPatchableCandidateCount -lt $MinAutoPatchableCandidates -and
                (Try-ExpandScope -Reason "scope_drain_mid_segment_candidate_shortage")) {
                Update-CandidatePocket
                [void](Commit-PathsIfNeeded -Paths @($LeasePath, $StatePath, $PocketPath) -Message "Expand Threshold scope drain segment $segment")
                continue
            }
            break
        }
        if ($state.terminalState -eq "budget_exhausted_verified") {
            break
        }

        Update-CandidatePocket
        [void](Commit-PathsIfNeeded -Paths @($PocketPath) -Message "Record Threshold scope drain segment $segment updated candidate pocket")
    }

    Update-CandidatePocket
    Mark-TerminalEvidenceSourceHead
    $state = Read-JsonFile -Path $StatePath
    [void](Commit-PathsIfNeeded -Paths @($LeasePath, $StatePath, $PocketPath) -Message "Record Threshold scope drain segment $segment terminal state")

    Write-Host "scopeDrainSegmentTerminalState=$($state.terminalState)"
    Write-Host "scopeDrainSegmentCandidatesProcessed=$($state.candidatesProcessed)"
    Write-Host "scopeDrainSegmentCommitsCreated=$($state.commitsCreated)"

    if ($state.terminalState -eq "ready_no_candidates_verified") {
        Set-ScopeDrainTerminalState -TerminalState "scope_exhausted_verified" -Reason "terminal segment verified no auto-patchable candidates remain"
        [void](Commit-PathsIfNeeded -Paths @($StatePath) -Message "Record Threshold scope drain completion")
        Write-Host "scopeDrainTerminalState=scope_exhausted_verified"
        Write-Host "scopeDrainSegmentsRun=$segment"
        Write-Host "scopeDrain=completed"
        exit 0
    }
}

Set-ScopeDrainTerminalState -TerminalState "segment_budget_exhausted_before_scope_exhaustion" -Reason "MaxSegments reached before a no-candidates terminal segment"
[void](Commit-PathsIfNeeded -Paths @($StatePath) -Message "Record Threshold scope drain segment limit")
Write-Host "scopeDrainTerminalState=segment_budget_exhausted_before_scope_exhaustion"
Write-Host "scopeDrainSegmentsRun=$segment"
Write-Host "scopeDrain=completed"
exit 0
