[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ThresholdCorePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/publication-preflight.ps1")

$cliPath = Join-Path $ThresholdCorePath "packages/refactoring-governor/dist/cli/thresholdRefactoringCliV0_1.js"
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) { throw "Canonical CLI not built: $cliPath" }
$head = (& git rev-parse HEAD).Trim()
$input = [ordered]@{
    authority = $null
    context = [ordered]@{
        repositoryRef = "fixture/Grüße_日本語_😀"
        branchRef = "fixture"
        subjectRef = "fixture:non-authorizing-contract-test"
        headSha = $head
        workorderDigest = "fixture-workorder"
        policyDigest = "fixture-policy"
        action = "push"
        now = "2026-11-05T00:00:00.000Z"
        consumedConsumptionIds = @()
    }
    verificationRef = "fixture:source-contract-only"
    reviewRef = "fixture:no-approval"
}
$inputJson = $input | ConvertTo-Json -Depth 100 -Compress
$expectedDigest = Get-CanonicalPublicationInputDigest -CliPath $cliPath -InputJson $inputJson
$reordered = [ordered]@{ reviewRef = $input.reviewRef; context = $input.context; authority = $null; verificationRef = $input.verificationRef }
$reorderedDigest = Get-CanonicalPublicationInputDigest -CliPath $cliPath -InputJson ($reordered | ConvertTo-Json -Depth 100 -Compress)
if ($reorderedDigest -cne $expectedDigest) { throw "Canonical input digest depends on JSON property order" }
$input.context.policyDigest = "fixture-tampered-policy"
$tamperedDigest = Get-CanonicalPublicationInputDigest -CliPath $cliPath -InputJson ($input | ConvertTo-Json -Depth 100 -Compress)
if ($tamperedDigest -ceq $expectedDigest) { throw "Canonical input digest omitted the policy context" }

$inputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-core-contract-" + [guid]::NewGuid().ToString("N") + ".json")
try {
    [System.IO.File]::WriteAllText($inputPath, $inputJson, [System.Text.UTF8Encoding]::new($false))
    $output = @(& node $cliPath validate-publication-authority --input $inputPath)
    $result = ConvertFrom-SingleJsonDocument -Text ($output -join "`n")
    Assert-CorePublicationAuthorityResult -Result $result -ExpectedHead $head -ExpectedInputDigest $expectedDigest
    if ($result.valid -ne $false -or $result.effectDecisions.publication.allowed -ne $false) {
        throw "Missing-authority contract fixture must remain non-authorizing"
    }
    Write-Host "publicationCoreContract=passed"
    Write-Host "runtimeAuthority=NONE"
    Write-Host "executionAuthorized=false"
}
finally { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue }
