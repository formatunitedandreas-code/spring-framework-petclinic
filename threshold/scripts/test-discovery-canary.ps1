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
$powerShellCommand = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($powerShellCommand)) {
    $powerShellCommand = (Get-Command powershell.exe -ErrorAction Stop).Source
}

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
    $propertyNames = @($Map.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($propertyNames -contains $Name) {
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

function Select-UniqueString {
    param([object[]] $Values)
    $seen = @{}
    foreach ($value in @($Values)) {
        $stringValue = [string]$value
        if ($seen.ContainsKey($stringValue)) {
            continue
        }
        $seen[$stringValue] = $true
        $stringValue
    }
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
if ($requiredDiscoverableClasses.Count -eq 0) {
    throw "Discovery canary expectation must declare requiredDiscoverableCandidateClasses or legacy requiredAutoPatchableCandidateClasses."
}
$requiredDiscoverableClasses = @(Select-UniqueString -Values $requiredDiscoverableClasses)
$fixtureRoot = ConvertTo-RepoPath ([string]$expected.fixtureRoot)
if (-not (Test-Path $fixtureRoot)) {
    throw "Discovery canary fixture root not found: $fixtureRoot"
}
if (-not (Test-Path $TrainerReportPath)) {
    throw "Discovery canary trainer report not found: $TrainerReportPath"
}

$head = (& git rev-parse HEAD).Trim()
$tempRunId = [guid]::NewGuid().ToString("N")
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-discovery-canary-$head-$tempRunId"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$tempPocket = Join-Path $tempRoot "pocket.json"
if (Test-Path $tempPocket) {
    Remove-Item -LiteralPath $tempPocket -Force
}

$output = @(
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
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

$tempTrainerReport = Join-Path $tempRoot "trainer.json"
$tempTrainerPocket = Join-Path $tempRoot "trainer-pocket.json"
$tempLegacyExpectedPath = Join-Path $tempRoot "legacy-expected.json"
$tempLegacyTrainerPath = Join-Path $tempRoot "legacy-trainer.json"
$tempMissingClassesExpectedPath = Join-Path $tempRoot "missing-classes-expected.json"
$tempMissingTrainerExpectedPath = Join-Path $tempRoot "missing-trainer-expected.json"
$tempExtraTrainerExpectedPath = Join-Path $tempRoot "extra-trainer-expected.json"
$tempExtraExecutionModeExpectedPath = Join-Path $tempRoot "extra-execution-mode-expected.json"
$tempWrongExecutionModeExpectedPath = Join-Path $tempRoot "wrong-execution-mode-expected.json"
$tempWrongTrainerExpectedPath = Join-Path $tempRoot "wrong-trainer-expected.json"
$tempDuplicateRequiredExpectedPath = Join-Path $tempRoot "duplicate-required-expected.json"
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
    if (Test-Path $tempMissingClassesExpectedPath) { Remove-Item -LiteralPath $tempMissingClassesExpectedPath -Force }
    if (Test-Path $tempMissingTrainerExpectedPath) { Remove-Item -LiteralPath $tempMissingTrainerExpectedPath -Force }
    if (Test-Path $tempExtraTrainerExpectedPath) { Remove-Item -LiteralPath $tempExtraTrainerExpectedPath -Force }
    if (Test-Path $tempExtraExecutionModeExpectedPath) { Remove-Item -LiteralPath $tempExtraExecutionModeExpectedPath -Force }
    if (Test-Path $tempWrongExecutionModeExpectedPath) { Remove-Item -LiteralPath $tempWrongExecutionModeExpectedPath -Force }
    if (Test-Path $tempWrongTrainerExpectedPath) { Remove-Item -LiteralPath $tempWrongTrainerExpectedPath -Force }
    if (Test-Path $tempDuplicateRequiredExpectedPath) { Remove-Item -LiteralPath $tempDuplicateRequiredExpectedPath -Force }
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
        & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
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
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $tempLegacyTrainerPath `
        -ExpectedPath $tempLegacyExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -ne 0) {
        throw "Discovery canary legacy expectation fallback regression failed."
    }

    $missingClassesExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        expectedTrainerDecisions = [ordered]@{
            annotation_attribute_wrap_cleanup = "autoPatchable"
        }
        nonClaims = @("missing discoverable classes negative fixture")
    }
    $missingClassesExpected | ConvertTo-Json -Depth 8 | Set-Content $tempMissingClassesExpectedPath
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $defaultTrainerReportPath `
        -ExpectedPath $tempMissingClassesExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary missing discoverable-class expectation regression unexpectedly passed."
    }
    $global:LASTEXITCODE = 0
    Write-Host "missingDiscoverableExpectationRejected=true"

    $missingTrainerExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "review_only"
        }
        expectedTrainerDecisions = [ordered]@{}
        nonClaims = @("missing trainer expectation negative fixture")
    }
    $missingTrainerExpected | ConvertTo-Json -Depth 8 | Set-Content $tempMissingTrainerExpectedPath
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $defaultTrainerReportPath `
        -ExpectedPath $tempMissingTrainerExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary missing trainer expectation regression unexpectedly passed."
    }
    $global:LASTEXITCODE = 0
    Write-Host "missingTrainerExpectationRejected=true"

    $extraTrainerExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "review_only"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "reviewOnly"
            undiscovered_fixture_class = "reviewOnly"
        }
        nonClaims = @("extra trainer expectation negative fixture")
    }
    $extraTrainerExpected | ConvertTo-Json -Depth 8 | Set-Content $tempExtraTrainerExpectedPath
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $defaultTrainerReportPath `
        -ExpectedPath $tempExtraTrainerExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary extra trainer expectation regression unexpectedly passed."
    }
    $global:LASTEXITCODE = 0
    Write-Host "extraTrainerExpectationRejected=true"

    $extraExecutionModeExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "review_only"
            undiscovered_fixture_class = "review_only"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "reviewOnly"
        }
        nonClaims = @("extra execution-mode expectation negative fixture")
    }
    $extraExecutionModeExpected | ConvertTo-Json -Depth 8 | Set-Content $tempExtraExecutionModeExpectedPath
    & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -LeasePath $defaultLeasePath `
        -GatePath $defaultGatePath `
        -TrainerReportPath $defaultTrainerReportPath `
        -ExpectedPath $tempExtraExecutionModeExpectedPath `
        -SkipInternalRegressions
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary extra execution-mode expectation regression unexpectedly passed."
    }
    $global:LASTEXITCODE = 0
    Write-Host "extraExecutionModeExpectationRejected=true"

    $wrongExecutionModeExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "auto_patchable"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "reviewOnly"
        }
        nonClaims = @("wrong execution-mode count negative fixture")
    }
    $wrongExecutionModeExpected | ConvertTo-Json -Depth 8 | Set-Content $tempWrongExecutionModeExpectedPath
    $wrongExecutionModeOutput = @(
        & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -LeasePath $defaultLeasePath `
            -GatePath $defaultGatePath `
            -TrainerReportPath $defaultTrainerReportPath `
            -ExpectedPath $tempWrongExecutionModeExpectedPath `
            -SkipInternalRegressions |
            ForEach-Object { [string]$_ }
    )
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary wrong execution-mode regression unexpectedly passed."
    }
    $wrongExecutionModeMismatchLines = @(
        $wrongExecutionModeOutput |
            Where-Object { $_ -like "executionModeMismatch=comment_wrap_cleanup *" }
    )
    if ($wrongExecutionModeMismatchLines.Count -ne 1) {
        throw "Discovery canary wrong execution-mode regression expected one mismatch line but observed $($wrongExecutionModeMismatchLines.Count)."
    }
    foreach ($line in $wrongExecutionModeOutput) {
        Write-Host $line
    }
    $global:LASTEXITCODE = 0
    Write-Host "executionModeMismatchCountedOnce=true"

    $wrongTrainerExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "review_only"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "autoPatchable"
        }
        nonClaims = @("wrong trainer-decision count negative fixture")
    }
    $wrongTrainerExpected | ConvertTo-Json -Depth 8 | Set-Content $tempWrongTrainerExpectedPath
    $wrongTrainerOutput = @(
        & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -LeasePath $defaultLeasePath `
            -GatePath $defaultGatePath `
            -TrainerReportPath $defaultTrainerReportPath `
            -ExpectedPath $tempWrongTrainerExpectedPath `
            -SkipInternalRegressions |
            ForEach-Object { [string]$_ }
    )
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary wrong trainer-decision regression unexpectedly passed."
    }
    $wrongTrainerMismatchLines = @(
        $wrongTrainerOutput |
            Where-Object { $_ -like "trainerDecisionMismatch=comment_wrap_cleanup *" }
    )
    if ($wrongTrainerMismatchLines.Count -ne 1) {
        throw "Discovery canary wrong trainer-decision regression expected one mismatch line but observed $($wrongTrainerMismatchLines.Count)."
    }
    foreach ($line in $wrongTrainerOutput) {
        Write-Host $line
    }
    $global:LASTEXITCODE = 0
    Write-Host "trainerDecisionMismatchCountedOnce=true"

    $duplicateRequiredExpected = [ordered]@{
        schemaVersion = "threshold.petclinic.discovery-canary.v0.1"
        fixtureRoot = [string]$defaultExpected.fixtureRoot
        requiredDiscoverableCandidateClasses = @("comment_wrap_cleanup", "comment_wrap_cleanup")
        expectedExecutionModes = [ordered]@{
            comment_wrap_cleanup = "auto_patchable"
        }
        expectedTrainerDecisions = [ordered]@{
            comment_wrap_cleanup = "autoPatchable"
        }
        nonClaims = @("duplicate required-class count negative fixture")
    }
    $duplicateRequiredExpected | ConvertTo-Json -Depth 8 | Set-Content $tempDuplicateRequiredExpectedPath
    $duplicateRequiredOutput = @(
        & $powerShellCommand -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -LeasePath $defaultLeasePath `
            -GatePath $defaultGatePath `
            -TrainerReportPath $defaultTrainerReportPath `
            -ExpectedPath $tempDuplicateRequiredExpectedPath `
            -SkipInternalRegressions |
            ForEach-Object { [string]$_ }
    )
    if ($LASTEXITCODE -eq 0) {
        throw "Discovery canary duplicate required-class regression unexpectedly passed."
    }
    $duplicateExecutionMismatchLines = @(
        $duplicateRequiredOutput |
            Where-Object { $_ -like "executionModeMismatch=comment_wrap_cleanup *" }
    )
    $duplicateTrainerMismatchLines = @(
        $duplicateRequiredOutput |
            Where-Object { $_ -like "trainerDecisionMismatch=comment_wrap_cleanup *" }
    )
    if ($duplicateExecutionMismatchLines.Count -ne 1) {
        throw "Discovery canary duplicate required-class regression expected one execution-mode mismatch line but observed $($duplicateExecutionMismatchLines.Count)."
    }
    if ($duplicateTrainerMismatchLines.Count -ne 1) {
        throw "Discovery canary duplicate required-class regression expected one trainer-decision mismatch line but observed $($duplicateTrainerMismatchLines.Count)."
    }
    foreach ($line in $duplicateRequiredOutput) {
        Write-Host $line
    }
    $global:LASTEXITCODE = 0
    Write-Host "requiredClassDeduplicationCountedOnce=true"
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
$requiredClassNames = @($requiredDiscoverableClasses | ForEach-Object { [string]$_ })

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

    $expectedTrainerDecision = Get-ExpectedMapValue -Map $expected.expectedTrainerDecisions -Name $candidateClass
    if ([string]::IsNullOrWhiteSpace($expectedTrainerDecision)) {
        throw "Discovery canary expectation missing expectedTrainerDecisions entry for '$candidateClass'."
    }
    $trainerDecision = @(
        $trainerReport.decisions |
            Where-Object { [string]$_.candidateClass -eq $candidateClass } |
            ForEach-Object { [string]$_.decision } |
            Sort-Object -Unique
    )
    if ($trainerDecision.Count -ne 1 -or $trainerDecision[0] -ne $expectedTrainerDecision) {
        $trainerDecisionMismatchCount++
        Write-Host "trainerDecisionMismatch=$candidateClass expected=$expectedTrainerDecision observed=$($trainerDecision -join ',')"
    }

    if ($expectedMode -ne "auto_patchable") {
        $unexpectedPromotions = @($classCandidates | Where-Object { $_.autoPatchable -eq $true })
        if ($unexpectedPromotions.Count -gt 0) {
            $unexpectedAutoPromotionCount += $unexpectedPromotions.Count
            Write-Host "unexpectedAutoPromotion=$candidateClass count=$($unexpectedPromotions.Count)"
        }
    }
}

foreach ($property in @($expected.expectedExecutionModes.PSObject.Properties)) {
    $candidateClass = [string]$property.Name
    $expectedMode = [string]$property.Value
    if ($requiredClassNames -contains $candidateClass) {
        continue
    }
    if ($visibleClasses -notcontains $candidateClass) {
        throw "Discovery canary expectation declared expectedExecutionModes entry for undiscovered class '$candidateClass'."
    }
    $classCandidates = @($pocket.candidates | Where-Object { [string]$_.candidateClass -eq $candidateClass })
    $observedModes = @($classCandidates | ForEach-Object { [string]$_.executionMode } | Sort-Object -Unique)
    if ($observedModes.Count -ne 1 -or $observedModes[0] -ne $expectedMode) {
        $executionModeMismatchCount++
        Write-Host "executionModeMismatch=$candidateClass expected=$expectedMode observed=$($observedModes -join ',')"
    }
}

foreach ($property in @($expected.expectedTrainerDecisions.PSObject.Properties)) {
    $candidateClass = [string]$property.Name
    $expectedTrainerDecision = [string]$property.Value
    if ($requiredClassNames -contains $candidateClass) {
        continue
    }
    if ($visibleClasses -notcontains $candidateClass) {
        throw "Discovery canary expectation declared expectedTrainerDecisions entry for undiscovered class '$candidateClass'."
    }
    $trainerDecision = @(
        $trainerReport.decisions |
            Where-Object { [string]$_.candidateClass -eq $candidateClass } |
            ForEach-Object { [string]$_.decision } |
            Sort-Object -Unique
    )
    if ($trainerDecision.Count -ne 1 -or $trainerDecision[0] -ne $expectedTrainerDecision) {
        $trainerDecisionMismatchCount++
        Write-Host "trainerDecisionMismatch=$candidateClass expected=$expectedTrainerDecision observed=$($trainerDecision -join ',')"
    }
}

if (Test-Path $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
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
Write-Host "trainerExpectationCoverageRequired=true"
Write-Host "declaredTrainerExpectationCoverageRequired=true"
Write-Host "declaredExecutionModeExpectationCoverageRequired=true"
Write-Host "executionModeMismatchCountedOnce=true"
Write-Host "trainerDecisionMismatchCountedOnce=true"
Write-Host "requiredClassDeduplicationCountedOnce=true"
Write-Host "missingRequiredCandidateClassCount=$missingRequiredCandidateClassCount"
Write-Host "executionModeMismatchCount=$executionModeMismatchCount"
Write-Host "trainerDecisionMismatchCount=$trainerDecisionMismatchCount"
Write-Host "discoverableClasses=$($visibleClasses -join ',')"
Write-Host "autoPatchableClasses=$($autoClasses -join ',')"
