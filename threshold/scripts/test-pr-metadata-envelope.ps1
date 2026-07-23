[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/pr-metadata-envelope.ps1")

function New-ValidBody {
    param([string] $EnvelopeOverride = "")

    $envelope = @'
{
  "schemaVersion": "threshold.h1b.pr-metadata.v0.2",
  "candidateClass": "industrial_refactoring_h1b",
  "cognitiveComplexity": { "before": 16, "after": 5 },
  "maximumNestingDepth": { "before": 3, "after": 2 },
  "methodLength": { "before": 39, "after": 17 },
  "responsibilityCount": { "before": 5, "after": 2 },
  "duplicateCursorLogic": { "before": 2, "after": 1 },
  "targetedTestsPassed": 27,
  "fullMavenTestsPassed": 126,
  "publicApiDelta": 0,
  "behaviorDelta": 0,
  "architectureViolationDelta": 0
}
'@
    if (-not [string]::IsNullOrEmpty($EnvelopeOverride)) {
        $envelope = $EnvelopeOverride
    }
    else {
        $envelope = $envelope.TrimEnd("`r", "`n") + "`n"
    }
    return "Human readable text may contain symbols outside the authoritative block.`n<!-- threshold-metadata-envelope:v0.2`n$envelope-->`n"
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    try {
        & $ScriptBlock
    }
    catch {
        Write-Host "passed=$Name"
        return
    }
    throw "Expected failure did not occur: $Name"
}

function Assert-DoesNotThrow {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    & $ScriptBlock | Out-Null
    Write-Host "passed=$Name"
}

Assert-DoesNotThrow -Name "valid ascii metadata envelope" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody)
}

Assert-Throws -Name "rejects U+001A in authoritative envelope" -ScriptBlock {
    $badEnvelope = (Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody)).Replace("16", "16$([char]0x001A)", [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects BOM" -ScriptBlock {
    $badEnvelope = "$([char]0xFEFF)$(Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody))"
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects CRLF" -ScriptBlock {
    $badEnvelope = (Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody)).Replace("`n", "`r`n", [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects missing final newline" -ScriptBlock {
    $badEnvelope = (Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody)).TrimEnd("`n")
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects additional final newline" -ScriptBlock {
    $badEnvelope = "$(Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody))`n"
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects field reordering" -ScriptBlock {
    $badEnvelope = @'
{
  "candidateClass": "industrial_refactoring_h1b",
  "schemaVersion": "threshold.h1b.pr-metadata.v0.2",
  "cognitiveComplexity": { "before": 16, "after": 5 },
  "maximumNestingDepth": { "before": 3, "after": 2 },
  "methodLength": { "before": 39, "after": 17 },
  "responsibilityCount": { "before": 5, "after": 2 },
  "duplicateCursorLogic": { "before": 2, "after": 1 },
  "targetedTestsPassed": 27,
  "fullMavenTestsPassed": 126,
  "publicApiDelta": 0,
  "behaviorDelta": 0,
  "architectureViolationDelta": 0
}
'@
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Write-Host "thresholdPrMetadataEnvelopeTests=passed"
