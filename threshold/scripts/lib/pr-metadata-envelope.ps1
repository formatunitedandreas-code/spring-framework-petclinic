[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$script:ThresholdPrMetadataEnvelopeStart = "<!-- threshold-metadata-envelope:v0.2"
$script:ThresholdPrMetadataEnvelopeEnd = "-->"
$script:ThresholdH1BMetadataCanonicalPattern = '(?s)^\{\n  "schemaVersion": "threshold\.h1b\.pr-metadata\.v0\.2",\n  "candidateClass": "industrial_refactoring_h1b",\n  "cognitiveComplexity": \{ "before": (?<cognitiveComplexityBefore>0|[1-9][0-9]*), "after": (?<cognitiveComplexityAfter>0|[1-9][0-9]*) \},\n  "maximumNestingDepth": \{ "before": (?<maximumNestingDepthBefore>0|[1-9][0-9]*), "after": (?<maximumNestingDepthAfter>0|[1-9][0-9]*) \},\n  "methodLength": \{ "before": (?<methodLengthBefore>0|[1-9][0-9]*), "after": (?<methodLengthAfter>0|[1-9][0-9]*) \},\n  "responsibilityCount": \{ "before": (?<responsibilityCountBefore>0|[1-9][0-9]*), "after": (?<responsibilityCountAfter>0|[1-9][0-9]*) \},\n  "duplicateCursorLogic": \{ "before": (?<duplicateCursorLogicBefore>0|[1-9][0-9]*), "after": (?<duplicateCursorLogicAfter>0|[1-9][0-9]*) \},\n  "targetedTestsPassed": (?<targetedTestsPassed>0|[1-9][0-9]*),\n  "fullMavenTestsPassed": (?<fullMavenTestsPassed>0|[1-9][0-9]*),\n  "publicApiDelta": (?<publicApiDelta>0),\n  "behaviorDelta": (?<behaviorDelta>0),\n  "architectureViolationDelta": (?<architectureViolationDelta>0)\n\}\n$'

function Get-ThresholdSubstringCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true)][string] $Needle
    )

    $count = 0
    $offset = 0
    while ($offset -lt $Text.Length) {
        $index = $Text.IndexOf($Needle, $offset, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        $count += 1
        $offset = $index + $Needle.Length
    }
    return $count
}

function Get-ThresholdPrMetadataEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body)

    $startCount = Get-ThresholdSubstringCount -Text $Body -Needle $script:ThresholdPrMetadataEnvelopeStart
    $endCount = Get-ThresholdSubstringCount -Text $Body -Needle $script:ThresholdPrMetadataEnvelopeEnd
    if ($startCount -eq 0) {
        throw "Missing Threshold PR metadata envelope marker."
    }
    if ($startCount -ne 1 -or $endCount -ne 1) {
        throw "Threshold PR metadata envelope must appear exactly once."
    }

    $start = $Body.IndexOf($script:ThresholdPrMetadataEnvelopeStart, [System.StringComparison]::Ordinal)
    $contentStart = $start + $script:ThresholdPrMetadataEnvelopeStart.Length
    if ($contentStart -lt $Body.Length -and $Body[$contentStart] -eq "`r") {
        throw "Threshold PR metadata envelope uses CRLF; LF is required."
    }
    if ($contentStart -ge $Body.Length -or $Body[$contentStart] -ne "`n") {
        throw "Threshold PR metadata envelope marker must be followed by LF."
    }
    $contentStart += 1

    $end = $Body.IndexOf($script:ThresholdPrMetadataEnvelopeEnd, $contentStart, [System.StringComparison]::Ordinal)
    if ($end -lt 0) {
        throw "Missing Threshold PR metadata envelope closing marker."
    }
    $content = $Body.Substring($contentStart, $end - $contentStart)
    if ($content.IndexOf($script:ThresholdPrMetadataEnvelopeStart, [System.StringComparison]::Ordinal) -ge 0 -or
        $content.IndexOf($script:ThresholdPrMetadataEnvelopeEnd, [System.StringComparison]::Ordinal) -ge 0) {
        throw "Threshold PR metadata envelope contains nested markers."
    }
    if ($content.EndsWith("`r`n", [System.StringComparison]::Ordinal)) {
        throw "Threshold PR metadata envelope uses CRLF; LF is required."
    }
    if (-not $content.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        throw "Threshold PR metadata envelope must end with exactly one LF before closing marker."
    }
    if ($content.EndsWith("`n`n", [System.StringComparison]::Ordinal)) {
        throw "Threshold PR metadata envelope has more than one trailing LF."
    }
    return $content
}

function Assert-ThresholdPrMetadataEnvelopeEncoding {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Envelope)

    if ($Envelope.Length -gt 0 -and [int]$Envelope[0] -eq 0xFEFF) {
        throw "Threshold PR metadata envelope must not contain a BOM."
    }
    for ($i = 0; $i -lt $Envelope.Length; $i++) {
        $codePoint = [int]$Envelope[$i]
        if ($codePoint -eq 0x0D) {
            throw "Threshold PR metadata envelope must use LF, not CRLF."
        }
        if ($codePoint -gt 0x7F) {
            throw "Threshold PR metadata envelope must be ASCII only."
        }
        if ($codePoint -lt 0x20 -and $codePoint -ne 0x0A) {
            throw "Threshold PR metadata envelope contains a forbidden control character."
        }
    }
}

function Assert-ThresholdPrMetadataPropertyOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Metadata,
        [Parameter(Mandatory = $true)] [string[]] $ExpectedOrder,
        [Parameter(Mandatory = $true)] [string] $Path
    )

    $actual = @($Metadata.PSObject.Properties.Name)
    if (($actual -join "`n") -ne ($ExpectedOrder -join "`n")) {
        throw "Threshold PR metadata property order mismatch at $Path. expected=[$($ExpectedOrder -join ', ')] actual=[$($actual -join ', ')]"
    }
}

function Assert-ThresholdH1BIntegerMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [int64] $Before,
        [Parameter(Mandatory = $true)] [int64] $After
    )

    if ($Before -lt 0 -or $After -lt 0) {
        throw "Threshold PR metadata metric '$Name' must be non-negative."
    }
    if ($After -ge $Before) {
        throw "Threshold PR metadata metric '$Name' must improve."
    }
}

function Get-ThresholdSha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-ThresholdPrMetadataEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body)

    $envelope = Get-ThresholdPrMetadataEnvelope -Body $Body
    Assert-ThresholdPrMetadataEnvelopeEncoding -Envelope $envelope

    $match = [regex]::Match($envelope, $script:ThresholdH1BMetadataCanonicalPattern)
    if (-not $match.Success) {
        throw "Threshold PR metadata envelope does not match the canonical H1-B JSON shape."
    }

    try {
        $metadata = $envelope | ConvertFrom-Json
    }
    catch {
        throw "Threshold PR metadata envelope is not valid JSON. $($_.Exception.Message)"
    }

    $topLevelOrder = @(
        "schemaVersion",
        "candidateClass",
        "cognitiveComplexity",
        "maximumNestingDepth",
        "methodLength",
        "responsibilityCount",
        "duplicateCursorLogic",
        "targetedTestsPassed",
        "fullMavenTestsPassed",
        "publicApiDelta",
        "behaviorDelta",
        "architectureViolationDelta"
    )
    Assert-ThresholdPrMetadataPropertyOrder -Metadata $metadata -ExpectedOrder $topLevelOrder -Path "$"

    if ([string]$metadata.schemaVersion -ne "threshold.h1b.pr-metadata.v0.2") {
        throw "Unsupported Threshold PR metadata schemaVersion."
    }
    if ([string]$metadata.candidateClass -ne "industrial_refactoring_h1b") {
        throw "Unsupported Threshold PR metadata candidateClass."
    }

    foreach ($metricName in @("cognitiveComplexity", "maximumNestingDepth", "methodLength", "responsibilityCount", "duplicateCursorLogic")) {
        $metric = $metadata.$metricName
        Assert-ThresholdPrMetadataPropertyOrder -Metadata $metric -ExpectedOrder @("before", "after") -Path "$.$metricName"
        Assert-ThresholdH1BIntegerMetric `
            -Name $metricName `
            -Before ([int64] $match.Groups["${metricName}Before"].Value) `
            -After ([int64] $match.Groups["${metricName}After"].Value)
    }

    foreach ($countName in @("targetedTestsPassed", "fullMavenTestsPassed")) {
        if ([int64]$match.Groups[$countName].Value -le 0) {
            throw "Threshold PR metadata '$countName' must be positive."
        }
    }
    foreach ($deltaName in @("publicApiDelta", "behaviorDelta", "architectureViolationDelta")) {
        if ([int64]$match.Groups[$deltaName].Value -ne 0) {
            throw "Threshold PR metadata '$deltaName' must be zero."
        }
    }

    [pscustomobject]@{
        metadataEnvelopeDigest = Get-ThresholdSha256Hex -Text $envelope
        metadataEnvelope = $metadata
    }
}

function Get-ThresholdReceiptSourceCommit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [pscustomobject] $Receipt)

    if ($Receipt.PSObject.Properties["sourceCommit"] -and $Receipt.sourceCommit) {
        return [string] $Receipt.sourceCommit
    }
    if ($Receipt.PSObject.Properties["commitHash"] -and $Receipt.commitHash) {
        return [string] $Receipt.commitHash
    }
    return ""
}

function Assert-ThresholdProductPrMetadataReceiptBinding {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Body,
        [Parameter(Mandatory = $true)] [object[]] $SourceReceiptEntries,
        [Parameter(Mandatory = $true)] [string[]] $KnownCandidateClasses,
        [Parameter(Mandatory = $true)] [string[]] $ExpectedSourceCommits
    )

    foreach ($expectedSourceCommit in $ExpectedSourceCommits) {
        $matches = @(
            $SourceReceiptEntries | Where-Object {
                (Get-ThresholdReceiptSourceCommit -Receipt $_.receipt) -eq $expectedSourceCommit
            }
        )
        if ($matches.Count -eq 0) {
            throw "Product source commit has no matching Threshold receipt: $expectedSourceCommit"
        }
    }

    $h1bEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $SourceReceiptEntries) {
        $receipt = $entry.receipt
        if (-not $receipt.PSObject.Properties["candidateClass"] -or [string]::IsNullOrWhiteSpace([string]$receipt.candidateClass)) {
            throw "Receipt is missing candidateClass: $($entry.path)"
        }
        $candidateClass = [string] $receipt.candidateClass
        if ($candidateClass -eq "industrial_refactoring_h1b") {
            $h1bEntries.Add($entry)
            continue
        }
        if ($KnownCandidateClasses -notcontains $candidateClass) {
            throw "Unknown product candidateClass '$candidateClass' in receipt: $($entry.path)"
        }
    }

    if ($h1bEntries.Count -eq 0) {
        return [pscustomobject]@{
            h1bMetadataRequired = $false
            observedMetadataEnvelopeDigest = $null
            expectedMetadataEnvelopeDigest = $null
        }
    }
    if ($h1bEntries.Count -gt 1) {
        throw "Multiple industrial_refactoring_h1b receipts found for product PR."
    }

    $h1bReceipt = $h1bEntries[0].receipt
    if (-not $h1bReceipt.PSObject.Properties["expectedMetadataEnvelopeDigest"] -or
        [string]::IsNullOrWhiteSpace([string]$h1bReceipt.expectedMetadataEnvelopeDigest)) {
        throw "H1-B receipt is missing expectedMetadataEnvelopeDigest."
    }

    $metadataResult = Assert-ThresholdPrMetadataEnvelope -Body $Body
    $expectedDigest = [string] $h1bReceipt.expectedMetadataEnvelopeDigest
    if ($metadataResult.metadataEnvelopeDigest -ne $expectedDigest) {
        throw "Threshold PR metadata digest mismatch. observed=$($metadataResult.metadataEnvelopeDigest) expected=$expectedDigest"
    }

    [pscustomobject]@{
        h1bMetadataRequired = $true
        observedMetadataEnvelopeDigest = $metadataResult.metadataEnvelopeDigest
        expectedMetadataEnvelopeDigest = $expectedDigest
    }
}
