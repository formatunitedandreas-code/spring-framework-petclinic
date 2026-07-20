[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $ExpectedPath = "threshold/discovery-canaries/expected.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

if (-not (Test-Path $ExpectedPath)) {
    throw "Discovery canary expectation file not found: $ExpectedPath"
}

$expected = Get-Content $ExpectedPath -Raw | ConvertFrom-Json
$fixtureRoot = ConvertTo-RepoPath ([string]$expected.fixtureRoot)
if (-not (Test-Path $fixtureRoot)) {
    throw "Discovery canary fixture root not found: $fixtureRoot"
}

$head = (& git rev-parse HEAD).Trim()
$tempPocket = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-$head.json"
if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}

$output = @(
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
        -LeasePath $LeasePath `
        -GatePath $GatePath `
        -SourceRoot $fixtureRoot `
        -PocketPath $tempPocket `
        -Limit 100
)
foreach ($line in $output) {
    Write-Host $line
}
if ($LASTEXITCODE -ne 0) {
    throw "Discovery canary candidate generation failed."
}

if (-not (Test-Path $tempPocket)) {
    throw "Discovery canary produced no pocket: $tempPocket"
}

$pocket = Get-Content $tempPocket -Raw | ConvertFrom-Json
$autoClasses = @(
    $pocket.candidates |
        Where-Object { $_.autoPatchable -eq $true } |
        ForEach-Object { [string]$_.candidateClass } |
        Sort-Object -Unique
)
$reviewOnlyClasses = @(
    $pocket.candidates |
        Where-Object { $_.reviewOnly -eq $true -or [string]$_.admission -eq "reviewOnly" } |
        ForEach-Object { [string]$_.candidateClass } |
        Sort-Object -Unique
)

foreach ($requiredClass in @($expected.requiredAutoPatchableCandidateClasses)) {
    if ($autoClasses -notcontains [string]$requiredClass) {
        throw "Discovery canary failed. Missing autoPatchable candidate class '$requiredClass'."
    }
}
foreach ($requiredClass in @($expected.requiredReviewOnlyCandidateClasses)) {
    if ($reviewOnlyClasses -notcontains [string]$requiredClass) {
        throw "Discovery canary failed. Missing reviewOnly candidate class '$requiredClass'."
    }
    if ($autoClasses -contains [string]$requiredClass) {
        throw "Discovery canary failed. ReviewOnly candidate class '$requiredClass' was autoPatchable."
    }
}

if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}

Write-Host "discoveryCanary=passed"
Write-Host "fixtureRoot=$fixtureRoot"
Write-Host "autoPatchableClasses=$($autoClasses -join ',')"
Write-Host "reviewOnlyClasses=$($reviewOnlyClasses -join ',')"
