[CmdletBinding()]
param(
    [string] $BaseRemote = "origin",
    [string] $BaseBranch = "main",
    [string] $LauncherPath = "threshold/scripts/start-next-wave.ps1",
    [string] $MainBranch = "main",
    [int] $MaxCycles = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-CleanWorktree {
    $status = @(& git status --porcelain)
    if ($status.Count -gt 0) {
        throw "Worktree is not clean."
    }
}

function Read-JsonFile {
    param([string] $Path)

    if (-not (Test-Path $Path)) {
        throw "JSON file not found: $Path"
    }

    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Sync-MainBranch {
    & git fetch $BaseRemote
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch $BaseRemote."
    }

    & git switch $MainBranch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to switch to $MainBranch."
    }

    & git pull --ff-only $BaseRemote $BaseBranch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fast-forward $MainBranch from $BaseRemote/$BaseBranch."
    }
}

function Invoke-NextWaveLauncher {
    param([string] $Path)

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $output) {
            Write-Host $line
        }
        throw "start-next-wave launcher failed."
    }

    foreach ($line in $output) {
        Write-Host $line
    }

    return $output
}

if ($MaxCycles -lt 1) {
    throw "MaxCycles must be at least 1."
}

$statePath = "threshold/lease-state/current-run.json"
$cycle = 0

while ($cycle -lt $MaxCycles) {
    $cycle++
    Assert-CleanWorktree
    Sync-MainBranch

    $launcherOutput = Invoke-NextWaveLauncher -Path $LauncherPath
    $launcherText = ($launcherOutput -join "`n")

    if ($launcherText -match "ready_no_candidates_on_fresh_wave") {
        Write-Host "waveCycleTerminalState=ready_no_candidates_on_fresh_wave"
        Write-Host "waveCycle=$cycle"
        break
    }

    $state = Read-JsonFile -Path $statePath
    Write-Host "waveCycle=$cycle"
    Write-Host "waveTerminalState=$($state.terminalState)"
    Write-Host "waveBranch=$($state.branch)"
    Write-Host "waveCurrentHead=$($state.currentHead)"

    if ($state.terminalState -ne "ready_no_candidates_verified") {
        break
    }

    if ($cycle -ge $MaxCycles) {
        break
    }

    Write-Host "waveCycleAutoAdvanced=true"
}

Write-Host "waveCycleCompleted=true"
Write-Host "waveCyclesRun=$cycle"
