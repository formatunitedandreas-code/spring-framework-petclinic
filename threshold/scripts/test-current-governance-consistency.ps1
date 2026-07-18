[CmdletBinding()]
param(
    [string] $LeasePath = "",
    [string] $StatePath = "",
    [string] $PocketPath = "",
    [string] $GatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/runtime-paths.ps1")

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

function Read-Json {
    param([string] $Path)
    if (-not (Test-Path $Path)) {
        throw "required_json_missing=$Path"
    }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Get-LeaseList {
    param([string[]] $Lines, [string] $Name)

    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") {
            $inside = $true
            continue
        }
        if ($inside -and $line -match "^\S") {
            break
        }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") {
            $items.Add(($Matches[1]).Trim())
        }
    }
    return @($items.ToArray())
}

function Get-UniqueMatches {
    param(
        [string] $Text,
        [string] $Pattern,
        [string] $GroupName
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($Text, $Pattern)) {
        $value = [string]$match.Groups[$GroupName].Value
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values.Add($value)
        }
    }
    return @($values | Sort-Object -Unique)
}

function Write-List {
    param([string] $Name, [string[]] $Values)
    Write-Host "$Name.count=$($Values.Count)"
    foreach ($value in $Values) {
        Write-Host "$Name.item=$value"
    }
}

function Compare-ClassSets {
    param(
        [string] $LeftName,
        [string[]] $Left,
        [string] $RightName,
        [string[]] $Right
    )

    $missingFromRight = @($Left | Where-Object { $Right -notcontains $_ })
    $missingFromLeft = @($Right | Where-Object { $Left -notcontains $_ })
    if ($missingFromRight.Count -gt 0) {
        foreach ($item in $missingFromRight) {
            Write-Host "classMismatch=$item presentIn=$LeftName missingFrom=$RightName"
        }
    }
    if ($missingFromLeft.Count -gt 0) {
        foreach ($item in $missingFromLeft) {
            Write-Host "classMismatch=$item presentIn=$RightName missingFrom=$LeftName"
        }
    }
}

function Assert-NoClassContractViolations {
    param(
        [string[]] $GateClasses,
        [string[]] $DiscoveryClasses,
        [string[]] $RunnerClasses,
        [string[]] $BatchClasses
    )

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($DiscoveryClasses | Where-Object { $GateClasses -notcontains $_ })) {
        $violations.Add("discovery_emits_ungated_class=$item")
    }
    foreach ($item in @($GateClasses | Where-Object { $RunnerClasses -notcontains $_ })) {
        $violations.Add("gate_class_missing_runner_executor=$item")
    }
    foreach ($item in @($BatchClasses | Where-Object { $GateClasses -notcontains $_ })) {
        $violations.Add("batch_class_missing_gate_entry=$item")
    }

    if ($violations.Count -gt 0) {
        foreach ($violation in $violations) {
            Write-Host "classContractViolation=$violation"
        }
        throw "Threshold auto-patchable class contract is inconsistent."
    }
}

$branch = (& git branch --show-current).Trim()
$head = (& git rev-parse HEAD).Trim()
$originMain = (& git rev-parse origin/main).Trim()
$statusLines = @(& git status --porcelain)
$aheadBehind = (& git rev-list --left-right --count "origin/main...HEAD").Trim()

Write-Host "thresholdGovernanceConsistency=started"
Write-Host "branch=$branch"
Write-Host "head=$head"
Write-Host "originMain=$originMain"
Write-Host "aheadBehindOriginMain=$aheadBehind"
Write-Host "worktreeDirty=$([bool]($statusLines.Count -gt 0))"

$state = Read-Json -Path $StatePath
Write-Host "state.path=$StatePath"
Write-Host "state.branch=$($state.branch)"
Write-Host "state.currentHead=$($state.currentHead)"
Write-Host "state.currentSourceHead=$($state.currentSourceHead)"
Write-Host "state.terminalState=$($state.terminalState)"

if ($state.terminalState -eq "active") {
    Write-Host "migrationDisposition=stop_migration_until_wave_terminal"
}
else {
    Write-Host "migrationDisposition=baseline_inventory_allowed"
}

$pocket = Read-Json -Path $PocketPath
Write-Host "pocket.path=$PocketPath"
Write-Host "pocket.branch=$($pocket.branch)"
Write-Host "pocket.generatedFromHead=$($pocket.generatedFromHead)"
Write-Host "pocket.candidateCount=$(@($pocket.candidates).Count)"

$pocketRepresentsTerminalSourceHead = $false
if ($state.terminalState -ne "active" -and
    $pocket.PSObject.Properties["generatedFromHeadRole"] -and
    [string]$pocket.generatedFromHeadRole -eq "sourceHead" -and
    [string]$pocket.generatedFromHead -eq [string]$state.currentHead) {
    $pocketRepresentsTerminalSourceHead = $true
    Write-Host "pocketIdentity=terminal_source_head_evidence"
}

if (($pocket.branch -ne $branch -or $pocket.generatedFromHead -ne $head) -and -not $pocketRepresentsTerminalSourceHead) {
    Write-Host "finding=stale_candidate_pocket"
    Write-Host "findingDetail=pocket identity does not match current branch/head"
}

$runtimePaths = @(
    $LeasePath,
    $StatePath,
    $PocketPath
)
foreach ($runtimePath in $runtimePaths) {
    $isTracked = $false
    & git ls-files --error-unmatch $runtimePath *> $null
    if ($LASTEXITCODE -eq 0) {
        $isTracked = $true
    }
    Write-Host "runtimePath=$runtimePath tracked=$isTracked"
}

$scriptFiles = @(
    "threshold/scripts/run-next-slice.ps1",
    "threshold/scripts/complete-slice.ps1",
    "threshold/scripts/validate-slice.ps1",
    "threshold/scripts/start-next-wave.ps1",
    "threshold/scripts/start-next-wave-cycle.ps1",
    "threshold/scripts/start-lease.ps1",
    "threshold/scripts/sync-lease-state.ps1",
    "threshold/scripts/discover-candidates.ps1",
    "threshold/scripts/record-receipt.ps1",
    "threshold/scripts/preflight.ps1",
    "threshold/scripts/expand-scope.ps1"
)

foreach ($runtimePath in $runtimePaths) {
    $references = @(
        Select-String -Path $scriptFiles -Pattern ([regex]::Escape($runtimePath)) -ErrorAction SilentlyContinue |
            ForEach-Object { "$(ConvertTo-RepoPath $_.Path):$($_.LineNumber)" }
    )
    Write-Host "runtimePathReference=$runtimePath count=$($references.Count)"
    foreach ($reference in $references) {
        Write-Host "runtimePathReferenceDetail=$reference"
    }
}

$leaseLines = Get-Content $LeasePath
$leaseCandidateTypes = @(Get-LeaseList -Lines $leaseLines -Name "allowedCandidateTypes")
$gate = Read-Json -Path $GatePath
$gateClasses = @($gate.approvedAutoPatchableCandidateClasses | ForEach-Object { [string]$_.candidateClass } | Sort-Object -Unique)
$batchClasses = @($gate.batchReceiptMode.approvedCandidateClasses | ForEach-Object { [string]$_.candidateClass } | Sort-Object -Unique)
$discoveryText = Get-Content "threshold/scripts/discover-candidates.ps1" -Raw
$discoveryLiteralClasses = @(Get-UniqueMatches -Text $discoveryText -Pattern 'Add-Candidate\s+-CandidateClass\s+"(?<class>[a-z0-9_]+)"' -GroupName "class")
$discoveryVariableClasses = @(Get-UniqueMatches -Text $discoveryText -Pattern '\$candidateClass\s*=\s*"(?<class>[a-z0-9_]+)"' -GroupName "class")
$discoveryClasses = @($discoveryLiteralClasses + $discoveryVariableClasses | Sort-Object -Unique)
$runnerText = Get-Content "threshold/scripts/run-next-slice.ps1" -Raw
$runnerClasses = @(Get-UniqueMatches -Text $runnerText -Pattern '"(?<class>[a-z0-9_]+)"\s*\{' -GroupName "class")
$runnerClasses = @($runnerClasses | Where-Object { $_ -like "*_*" -and $_ -ne "collapse_extra_blank_line" } | Sort-Object -Unique)

Write-List -Name "leaseCandidateTypes" -Values $leaseCandidateTypes
Write-List -Name "gateAutoPatchableClasses" -Values $gateClasses
Write-List -Name "batchAutoPatchableClasses" -Values $batchClasses
Write-List -Name "discoveryCandidateClasses" -Values $discoveryClasses
Write-List -Name "runnerExecutorClasses" -Values $runnerClasses

Compare-ClassSets -LeftName "lease" -Left $leaseCandidateTypes -RightName "gate" -Right $gateClasses
Compare-ClassSets -LeftName "lease" -Left $leaseCandidateTypes -RightName "discovery" -Right $discoveryClasses
Compare-ClassSets -LeftName "gate" -Left $gateClasses -RightName "runner" -Right $runnerClasses
Assert-NoClassContractViolations -GateClasses $gateClasses -DiscoveryClasses $discoveryClasses -RunnerClasses $runnerClasses -BatchClasses $batchClasses

$publicationLines = @(
    Select-String -Path "threshold/scripts/start-next-wave.ps1" -Pattern "git.*push|pr.*create|pr.*checks|pr.*merge|Assert-ReadyForMerge|mergeable|draft"
)
Write-Host "publicationMergeBehaviorReferences.count=$($publicationLines.Count)"
foreach ($line in $publicationLines) {
    Write-Host "publicationMergeBehaviorReference=$(ConvertTo-RepoPath $line.Path):$($line.LineNumber):$($line.Line.Trim())"
}

Write-Host "thresholdGovernanceConsistency=completed"
