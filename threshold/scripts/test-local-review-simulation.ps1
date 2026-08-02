[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $TrainerReportPath = "threshold/trainer/training-report.json",
    [string] $FixtureRoot = "threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Resolve-PowerShellCommand {
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwshCommand -and -not [string]::IsNullOrWhiteSpace([string]$pwshCommand.Source)) {
        return [string]$pwshCommand.Source
    }

    $windowsPowerShellCommand = Get-Command powershell.exe -ErrorAction Stop
    if ($null -eq $windowsPowerShellCommand -or [string]::IsNullOrWhiteSpace([string]$windowsPowerShellCommand.Source)) {
        throw "Unable to resolve a PowerShell command for local review simulation."
    }
    return [string]$windowsPowerShellCommand.Source
}

$powerShellCommand = Resolve-PowerShellCommand
$simulationLeasePath = "threshold/leases/current.yaml"
$simulationGatePath = "threshold/gates/auto-patchable-candidate-classes.json"
$simulationTrainerReportPath = "threshold/trainer/training-report.json"
foreach ($simulationInputPath in @($simulationLeasePath, $simulationGatePath, $simulationTrainerReportPath)) {
    if (-not (Test-Path $simulationInputPath)) {
        throw "Local review simulation repo-owned input not found: $simulationInputPath"
    }
}

function Invoke-DiscoveryCanarySimulation {
    param(
        [string] $Name,
        [hashtable] $Expected,
        [int] $ExpectedExitCode,
        [hashtable] $ExpectedLineCounts
    )

    $expectedPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-local-review-simulation-$Name.json"
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-local-review-simulation-$Name.stderr.txt"
    if (Test-Path $expectedPath) {
        Remove-Item -LiteralPath $expectedPath -Force
    }
    if (Test-Path $stderrPath) {
        Remove-Item -LiteralPath $stderrPath -Force
    }
    $Expected | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $expectedPath
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $rawOutput = & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-discovery-canary.ps1" `
                -LeasePath $simulationLeasePath `
                -GatePath $simulationGatePath `
                -TrainerReportPath $simulationTrainerReportPath `
                -ExpectedPath $expectedPath `
                -SkipInternalRegressions 2> $stderrPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $output = @($rawOutput | ForEach-Object { [string]$_ })
    }
    finally {
        if (Test-Path $expectedPath) {
            Remove-Item -LiteralPath $expectedPath -Force
        }
    }
    $stderrOutput = @()
    if (Test-Path $stderrPath) {
        $stderrOutput = @(Get-Content -LiteralPath $stderrPath | ForEach-Object { [string]$_ })
        Remove-Item -LiteralPath $stderrPath -Force
    }

    if ($exitCode -ne $ExpectedExitCode) {
        foreach ($line in $output) { Write-Host $line }
        foreach ($line in $stderrOutput) { Write-Host $line }
        throw "Local review simulation '$Name' expected exit $ExpectedExitCode but observed $exitCode."
    }

    foreach ($pattern in @($ExpectedLineCounts.Keys)) {
        $actualCount = @($output | Where-Object { $_ -match $pattern }).Count
        $expectedCount = [int]$ExpectedLineCounts[$pattern]
        if ($actualCount -ne $expectedCount) {
            foreach ($line in $output) { Write-Host $line }
            foreach ($line in $stderrOutput) { Write-Host $line }
            throw "Local review simulation '$Name' expected $expectedCount line(s) matching '$pattern' but observed $actualCount."
        }
    }

    Write-Host "localReviewSimulationCase=$Name passed=true"
}

$reviewSimulationFamilies = @(
    "required_class_deduplication",
    "execution_mode_mismatch_single_count",
    "trainer_decision_mismatch_single_count",
    "legacy_expectation_fallback_deduplication",
    "missing_required_class_single_count"
)

Write-Host "localReviewSimulation=started"
Write-Host "sourceFindingCorpus=threshold.petclinic.discovery-canary.semantic-reconciliation"
Write-Host "reviewSimulationFamilies=$($reviewSimulationFamilies -join ',')"

Invoke-DiscoveryCanarySimulation `
    -Name "duplicate_missing_required_class_counted_once" `
    -Expected ([ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = $FixtureRoot
        requiredDiscoverableCandidateClasses = @("missing_fixture_class", "missing_fixture_class")
        expectedExecutionModes = [ordered]@{}
        expectedTrainerDecisions = [ordered]@{}
        nonClaims = @("local review simulation for duplicate missing required classes")
    }) `
    -ExpectedExitCode 1 `
    -ExpectedLineCounts @{
        "^missingRequiredCandidateClass=missing_fixture_class$" = 1
    }

Invoke-DiscoveryCanarySimulation `
    -Name "duplicate_required_execution_and_trainer_mismatch_counted_once" `
    -Expected ([ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = $FixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup", "comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "auto_patchable"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "autoPatchable"
        }
        nonClaims = @("local review simulation for duplicate required mismatch counts")
    }) `
    -ExpectedExitCode 1 `
    -ExpectedLineCounts @{
        "^executionModeMismatch=comment_wrap_cleanup " = 1
        "^trainerDecisionMismatch=comment_wrap_cleanup " = 1
    }

Invoke-DiscoveryCanarySimulation `
    -Name "duplicate_legacy_required_class_fallback" `
    -Expected ([ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = $FixtureRoot
        requiredAutoPatchableCandidateClasses = @("annotation_attribute_wrap_cleanup", "annotation_attribute_wrap_cleanup")
        nonClaims = @("local review simulation for duplicate legacy fallback classes")
    }) `
    -ExpectedExitCode 0 `
    -ExpectedLineCounts @{
        "^discoveryCanary=passed$" = 1
        "^legacyExpectationFallbackUsed=True$" = 1
        "^unexpectedAutoPromotionCount=0$" = 1
    }

Write-Host "localReviewSimulation=passed"
Write-Host "externalCodexReviewStillRequired=true"
