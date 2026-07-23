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

$validEnvelopeDigest = "69699fe178bd38658463deb35d6621594ead1b5aec377f659968efe0e3f447d5"
$validEnvelope = Get-ThresholdPrMetadataEnvelope -Body (New-ValidBody)

Assert-DoesNotThrow -Name "valid ascii metadata envelope" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody)
}

Assert-DoesNotThrow -Name "golden digest matches fixed expected value" -ScriptBlock {
    $result = Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody)
    if ($result.metadataEnvelopeDigest -ne $validEnvelopeDigest) {
        throw "Golden metadata digest mismatch. observed=$($result.metadataEnvelopeDigest) expected=$validEnvelopeDigest"
    }
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

Assert-Throws -Name "rejects numeric strings" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"before": 16', '"before": "16"', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects boolean numeric values" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"after": 5', '"after": true', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects null values" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"targetedTestsPassed": 27', '"targetedTestsPassed": null', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects floating-point values" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"before": 16', '"before": 16.0', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects scientific notation" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"fullMavenTestsPassed": 126', '"fullMavenTestsPassed": 1e2', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects negative values" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"after": 5', '"after": -1', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects duplicate top-level property" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"candidateClass": "industrial_refactoring_h1b",', '"candidateClass": "industrial_refactoring_h1b",\n  "candidateClass": "industrial_refactoring_h1b",', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects duplicate nested before property" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"cognitiveComplexity": { "before": 16, "after": 5 }', '"cognitiveComplexity": { "before": 16, "before": 15, "after": 5 }', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "rejects two envelopes" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body "$(New-ValidBody)`n$(New-ValidBody)"
}

Assert-DoesNotThrow -Name "ordinary HTML comment before envelope passes" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body "<!-- repository template hint -->`n$(New-ValidBody)"
}

Assert-DoesNotThrow -Name "ordinary HTML comment after envelope passes" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body "$(New-ValidBody)`n<!-- repository template hint -->"
}

Assert-DoesNotThrow -Name "ordinary HTML comments before and after envelope pass" -ScriptBlock {
    Assert-ThresholdPrMetadataEnvelope -Body "<!-- before -->`n$(New-ValidBody)`n<!-- after -->"
}

Assert-Throws -Name "rejects nested start marker" -ScriptBlock {
    $badEnvelope = $validEnvelope.Replace('"candidateClass": "industrial_refactoring_h1b",', '"candidateClass": "industrial_refactoring_h1b",\n<!-- threshold-metadata-envelope:v0.2', [System.StringComparison]::Ordinal)
    Assert-ThresholdPrMetadataEnvelope -Body (New-ValidBody -EnvelopeOverride $badEnvelope)
}

Assert-Throws -Name "missing Threshold closing marker fails" -ScriptBlock {
    $body = New-ValidBody
    $body = $body.Substring(0, $body.LastIndexOf("-->", [System.StringComparison]::Ordinal))
    Assert-ThresholdPrMetadataEnvelope -Body $body
}

function New-ReceiptEntry {
    param(
        [string] $SourceCommit = "1111111111111111111111111111111111111111",
        [string] $CandidateClass = "industrial_refactoring_h1b",
        [string] $ExpectedDigest = $validEnvelopeDigest,
        [switch] $OmitDigest
    )

    $receipt = [ordered]@{
        sourceCommit = $SourceCommit
        candidateClass = $CandidateClass
        changedFiles = @("src/main/java/Example.java")
    }
    if (-not $OmitDigest) {
        $receipt.expectedMetadataEnvelopeDigest = $ExpectedDigest
    }
    [pscustomobject]@{
        path = "threshold/receipts/test-receipt.json"
        receipt = [pscustomobject]$receipt
    }
}

Assert-DoesNotThrow -Name "valid exact H1-B envelope and receipt binding passes" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry)) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "digest mismatch fails" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -ExpectedDigest "0000000000000000000000000000000000000000000000000000000000000000")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "missing expected digest fails" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -OmitDigest)) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "wrong source commit fails" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -SourceCommit "2222222222222222222222222222222222222222")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-DoesNotThrow -Name "wrong candidate class does not invoke H1-B parser" -ScriptBlock {
    $result = Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body "No H1-B metadata needed for this known cleanup class." `
        -SourceReceiptEntries @((New-ReceiptEntry -CandidateClass "comment_wrap_cleanup" -OmitDigest)) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
    if ($result.h1bMetadataRequired) {
        throw "Known non-H1-B candidate class unexpectedly required H1-B metadata."
    }
}

Assert-Throws -Name "unknown candidate class fails closed" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body "No metadata." `
        -SourceReceiptEntries @((New-ReceiptEntry -CandidateClass "unknown_candidate" -OmitDigest)) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "multiple H1-B receipts fail" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry), (New-ReceiptEntry -ExpectedDigest "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "conflicting expected digests fail" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry), (New-ReceiptEntry -ExpectedDigest "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-DoesNotThrow -Name "product commit plus separate receipt-only commit passes" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -SourceCommit "1111111111111111111111111111111111111111")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-DoesNotThrow -Name "receipt-only commit is excluded from expected source commits" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -SourceCommit "1111111111111111111111111111111111111111")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-Throws -Name "product commit without receipt fails" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -SourceCommit "2222222222222222222222222222222222222222")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("1111111111111111111111111111111111111111")
}

Assert-DoesNotThrow -Name "mixed product-and-receipt commit passes" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body (New-ValidBody) `
        -SourceReceiptEntries @((New-ReceiptEntry -SourceCommit "3333333333333333333333333333333333333333")) `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @("3333333333333333333333333333333333333333")
}

Assert-DoesNotThrow -Name "governance-only commit remains excluded" -ScriptBlock {
    Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body "No product metadata needed." `
        -SourceReceiptEntries @() `
        -KnownCandidateClasses @("comment_wrap_cleanup") `
        -ExpectedSourceCommits @()
}

Write-Host "thresholdPrMetadataEnvelopeTests=passed"
