[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $TrainerReportPath = "threshold/trainer/training-report.json",
    [string] $ExpectedPath = "threshold/discovery-canaries/expected.json",
    [switch] $SkipInternalRegressions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$defaultLeasePath = "threshold/leases/current.yaml"
$defaultGatePath = "threshold/gates/auto-patchable-candidate-classes.json"
$defaultTrainerReportPath = "threshold/trainer/training-report.json"
$defaultExpectedPath = "threshold/discovery-canaries/expected.json"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function Get-JsonProperty {
    param([object] $Object, [string] $Name, [object] $DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $DefaultValue
}

function Get-ExpectedMapValue {
    param([object] $Map, [string] $Name)
    if ($null -eq $Map) { return "" }
    if ($Map.PSObject.Properties.Name -contains $Name) {
        return [string]$Map.$Name
    }
    return ""
}

function Add-JsonProperty {
    param([pscustomobject] $Object, [string] $Name, [object] $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
        return
    }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

if (-not (Test-Path $ExpectedPath)) {
    throw "Discovery canary expectation file not found: $ExpectedPath"
}

$expected = Get-Content $ExpectedPath -Raw | ConvertFrom-Json
$requiredDiscoverableClasses = @(Get-JsonProperty $expected "requiredDiscoverableCandidateClasses" @())
$legacyRequiredAutoPatchableClasses = @(Get-JsonProperty $expected "requiredAutoPatchableCandidateClasses" @())
$legacyExpectationFallbackUsed = $false
if ($requiredDiscoverableClasses.Count -eq 0 -and $legacyRequiredAutoPatchableClasses.Count -gt 0) {
    $legacyExpectationFallbackUsed = $true
    $requiredDiscoverableClasses = @($legacyRequiredAutoPatchableClasses)
    $expectedExecutionModes = [ordered]@{}
    $expectedTrainerDecisions = [ordered]@{}
    foreach ($legacyClass in $requiredDiscoverableClasses) {
        $candidateClass = [string]$legacyClass
        $expectedExecutionModes[$candidateClass] = "auto_patchable"
        $expectedTrainerDecisions[$candidateClass] = "autoPatchable"
    }
    Add-JsonProperty -Object $expected -Name "expectedExecutionModes" -Value ([pscustomobject]$expectedExecutionModes)
    Add-JsonProperty -Object $expected -Name "expectedTrainerDecisions" -Value ([pscustomobject]$expectedTrainerDecisions)
}
$fixtureRoot = ConvertTo-RepoPath ([string]$expected.fixtureRoot)
if (-not (Test-Path $fixtureRoot)) {
    throw "Discovery canary fixture root not found: $fixtureRoot"
}
if (-not (Test-Path $TrainerReportPath)) {
    throw "Discovery canary trainer report not found: $TrainerReportPath"
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
        -TrainerReportPath $TrainerReportPath `
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
$trainerReport = Get-Content $TrainerReportPath -Raw | ConvertFrom-Json

$tempTrainerReport = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-trainer-$head.json"
$tempTrainerPocket = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-trainer-pocket-$head.json"
$tempLegacyExpectedPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-legacy-expected-$head.json"
$tempLegacyTrainerPath = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-legacy-trainer-$head.json"
if (-not $SkipInternalRegressions.IsPresent) {
    foreach ($repoOwnedPath in @($defaultLeasePath, $defaultGatePath, $defaultTrainerReportPath, $defaultExpectedPath)) {
        if (-not (Test-Path $repoOwnedPath)) {
            throw "Discovery canary internal regression input not found: $repoOwnedPath"
        }
    }
    $defaultExpected = Get-Content $defaultExpectedPath -Raw | ConvertFrom-Json
    $defaultFixtureRoot = ConvertTo-RepoPath ([string]$defaultExpected.fixtureRoot)
    if (-not (Test-Path $defaultFixtureRoot)) {
        throw "Discovery canary internal regression fixture root not found: $defaultFixtureRoot"
    }

    if (Test-Path $tempTrainerReport) { Remove-Item -LiteralPath $tempTrainerReport -Force }
    if (Test-Path $tempTrainerPocket) { Remove-Item -LiteralPath $tempTrainerPocket -Force }
    if (Test-Path $tempLegacyExpectedPath) { Remove-Item -LiteralPath $tempLegacyExpectedPath -Force }
    if (Test-Path $tempLegacyTrainerPath) { Remove-Item -LiteralPath $tempLegacyTrainerPath -Force }
    $alternateTrainerReport = Get-Content $defaultTrainerReportPath -Raw | ConvertFrom-Json
    $alternateDecision = @(
        $alternateTrainerReport.decisions |
            Where-Object { [string]$_.candidateClass -eq "annotation_attribute_wrap_cleanup" } |
            Select-Object -First 1
    )
    if ($alternateDecision.Count -ne 1) {
        throw "Discovery canary trainer report missing annotation_attribute_wrap_cleanup decision."
    }
    $alternateDecision[0].decision = "reviewOnly"
    $alternateTrainerReport | ConvertTo-Json -Depth 16 | Set-Content $tempTrainerReport

    $alternateOutput = @(
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
            -LeasePath $defaultLeasePath `
            -GatePath $defaultGatePath `
            -TrainerReportPath $tempTrainerReport `
            -SourceRoot $defaultFixtureRoot `
            -PocketPath $tempTrainerPocket `
            -Limit 100
    )
    foreach ($line in $alternateOutput) {
        Write-Host $line
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Discovery canary alternate trainer candidate generation failed."
    }
    if (-not (Test-Path $tempTrainerPocket)) {
        throw "Discovery canary alternate trainer produced no pocket: $tempTrainerPocket"
    }
    $alternatePocket = Get-Content $tempTrainerPocket -Raw | ConvertFrom-Json
    $alternateAnnotationCandidates = @(
        $alternatePocket.candidates |
            Where-Object { [string]$_.candidateClass -eq "annotation_attribute_wrap_cleanup" }
    )
    if ($alternateAnnotationCandidates.Count -lt 1) {
        throw "Discovery canary alternate trainer produced no annotation_attribute_wrap_cleanup candidate."
    }
    $alternateAnnotationModes = @($alternateAnnotationCandidates | ForEach-Object { [string]$_.executionMode } | Sort-Object -Unique)
    if ($alternateAnnotationModes.Count -ne 1 -or $alternateAnnotationModes[0] -ne "review_only") {
        throw "Discovery canary did not pass selected trainer report to discovery. expected=review_only observed=$($alternateAnnotationModes -join ',')"
    }
    $alternateAnnotationAutoPatchable = @($alternateAnnotationCandidates | Where-Object { $_.autoPatchable -eq $true })
    if ($alternateAnnotationAutoPatchable.Count -ne 0) {
        throw "Discovery canary alternate trainer unexpectedly auto-promoted annotation_attribute_wrap_cleanup."
    }

    $legacyExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredAutoPatchableCandidateClasses = @("annotation_attribute_wrap_cleanup")
        nonClaims = @("legacy fallback fixture")
    }
    $legacyExpected | ConvertTo-Json -Depth 8 | Set-Content $tempLegacyExpectedPath
    $legacyTrainerReport = Get-Content $defaultTrainerReportPath -Raw | ConvertFrom-Json
    $legacyTrainerDecision = @(
        $legacyTrainerReport.decisions |
            Where-Object { [string]$_.candidateClass -eq "annotation_attribute_wrap_cleanup" } |
            Select-Object -First 1
    )
    if ($legacyTrainerDecision.Count -ne 1) {
        throw "Discovery canary legacy fallback trainer report missing annotation_attribute_wrap_cleanup decision."
    }
    $legacyTrainerDecision[0].decision = "autoPatchable"
    $legacyTrainerReport | ConvertTo-Json -Depth 16 | Set-Content $tempLegacyTrainerPath
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $tempLegacyTrainerPath `
        -ExpectedPath $tempLegacyExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -ne 0) {
        throw "Discovery canary legacy expectation fallback regression failed."
    }
}

$visibleClasses = @(
    $pocket.candidates |
        ForEach-Object { [string]$_.candidateClass } |
        Sort-Object -Unique
)
$autoClasses = @(
    $pocket.candidates |
        Where-Object { $_.autoPatchable -eq $true } |
        ForEach-Object { [string]$_.candidateClass } |
        Sort-Object -Unique
)
$unexpectedAutoPromotionCount = 0
$missingRequiredCandidateClassCount = 0
$executionModeMismatchCount = 0
$trainerDecisionMismatchCount = 0

foreach ($requiredClass in @($requiredDiscoverableClasses)) {
    $candidateClass = [string]$requiredClass
    if ($visibleClasses -notcontains $candidateClass) {
        $missingRequiredCandidateClassCount++
        Write-Host "missingRequiredCandidateClass=$candidateClass"
        continue
    }

    $classCandidates = @($pocket.candidates | Where-Object { [string]$_.candidateClass -eq $candidateClass })
    $observedModes = @($classCandidates | ForEach-Object { [string]$_.executionMode } | Sort-Object -Unique)
    $expectedMode = Get-ExpectedMapValue -Map $expected.expectedExecutionModes -Name $candidateClass
    if ([string]::IsNullOrWhiteSpace($expectedMode)) {
        throw "Discovery canary expectation missing expectedExecutionModes entry for '$candidateClass'."
    }
    if ($observedModes.Count -ne 1 -or $observedModes[0] -ne $expectedMode) {
        $executionModeMismatchCount++
        Write-Host "executionModeMismatch=$candidateClass expected=$expectedMode observed=$($observedModes -join ',')"
    }

    if ($expectedMode -ne "auto_patchable") {
        $unexpectedPromotions = @($classCandidates | Where-Object { $_.autoPatchable -eq $true })
        if ($unexpectedPromotions.Count -gt 0) {
            $unexpectedAutoPromotionCount += $unexpectedPromotions.Count
            Write-Host "unexpectedAutoPromotion=$candidateClass count=$($unexpectedPromotions.Count)"
        }
    }
}

foreach ($property in @($expected.expectedTrainerDecisions.PSObject.Properties)) {
    $candidateClass = [string]$property.Name
    $expectedDecision = [string]$property.Value
    $trainerDecision = @(
        $trainerReport.decisions |
            Where-Object { [string]$_.candidateClass -eq $candidateClass } |
            ForEach-Object { [string]$_.decision } |
            Sort-Object -Unique
    )
    if ($trainerDecision.Count -ne 1 -or $trainerDecision[0] -ne $expectedDecision) {
        $trainerDecisionMismatchCount++
        Write-Host "trainerDecisionMismatch=$candidateClass expected=$expectedDecision observed=$($trainerDecision -join ',')"
    }
}

if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}
if (Test-Path $tempTrainerReport) {
    Remove-Item -LiteralPath $tempTrainerReport -Force
}
if (Test-Path $tempTrainerPocket) {
    Remove-Item -LiteralPath $tempTrainerPocket -Force
}
if (Test-Path $tempLegacyExpectedPath) {
    Remove-Item -LiteralPath $tempLegacyExpectedPath -Force
}
if (Test-Path $tempLegacyTrainerPath) {
    Remove-Item -LiteralPath $tempLegacyTrainerPath -Force
}

$discoveryVisibilityMatched = ($missingRequiredCandidateClassCount -eq 0)
$executionModeMatched = ($executionModeMismatchCount -eq 0)
$trainerDecisionMatched = ($trainerDecisionMismatchCount -eq 0)
if (-not $discoveryVisibilityMatched -or
    -not $executionModeMatched -or
    -not $trainerDecisionMatched -or
    $unexpectedAutoPromotionCount -ne 0) {
    throw "Discovery canary failed semantic reconciliation."
}

Write-Host "discoveryCanary=passed"
Write-Host "fixtureRoot=$fixtureRoot"
Write-Host "discoveryVisibilityMatched=$discoveryVisibilityMatched"
Write-Host "executionModeMatched=$executionModeMatched"
Write-Host "trainerDecisionMatched=$trainerDecisionMatched"
Write-Host "unexpectedAutoPromotionCount=$unexpectedAutoPromotionCount"
Write-Host "selectedTrainerReportForwarded=true"
Write-Host "legacyExpectationFallbackUsed=$legacyExpectationFallbackUsed"
Write-Host "missingRequiredCandidateClassCount=$missingRequiredCandidateClassCount"
Write-Host "executionModeMismatchCount=$executionModeMismatchCount"
Write-Host "trainerDecisionMismatchCount=$trainerDecisionMismatchCount"
Write-Host "discoverableClasses=$($visibleClasses -join ',')"
Write-Host "autoPatchableClasses=$($autoClasses -join ',')"
