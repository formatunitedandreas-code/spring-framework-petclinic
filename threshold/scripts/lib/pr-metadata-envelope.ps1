[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$script:ThresholdPrMetadataEnvelopeStart = "<!-- threshold-metadata-envelope:v0.2"
$script:ThresholdPrMetadataEnvelopeEnd = "-->"

function Get-ThresholdPrMetadataEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Body)

    $start = $Body.IndexOf($script:ThresholdPrMetadataEnvelopeStart, [System.StringComparison]::Ordinal)
    if ($start -lt 0) {
        throw "Missing Threshold PR metadata envelope marker."
    }
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
        if ([int]$metric.after -ge [int]$metric.before) {
            throw "Threshold PR metadata metric '$metricName' must improve."
        }
    }

    foreach ($countName in @("targetedTestsPassed", "fullMavenTestsPassed")) {
        if ([int]$metadata.$countName -le 0) {
            throw "Threshold PR metadata '$countName' must be positive."
        }
    }
    foreach ($deltaName in @("publicApiDelta", "behaviorDelta", "architectureViolationDelta")) {
        if ([int]$metadata.$deltaName -ne 0) {
            throw "Threshold PR metadata '$deltaName' must be zero."
        }
    }

    [pscustomobject]@{
        metadataEnvelopeDigest = Get-ThresholdSha256Hex -Text $envelope
        metadataEnvelope = $metadata
    }
}
