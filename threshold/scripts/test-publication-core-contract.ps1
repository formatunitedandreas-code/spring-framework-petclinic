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
    $validatorCode = $LASTEXITCODE
    $result = ConvertFrom-SingleJsonDocument -Text ($output -join "`n")
    Assert-CorePublicationAuthorityResult -Result $result -ExpectedHead $head -ExpectedInputDigest $expectedDigest
    if ($result.valid -ne $false -or $result.effectDecisions.publication.allowed -ne $false) {
        throw "Missing-authority contract fixture must remain non-authorizing"
    }
    if ($validatorCode -ne 2) { throw "Missing-authority CLI must return its denied-result status" }
    $input.context.workorderDigest = Get-PreflightSubjectDigest -ChangedPaths @("fixture.txt") -Head $head
    $input.context.policyDigest = Get-PolicyDigest
    $input.authority = [ordered]@{
        schemaVersion = "threshold.one-shot-authority.v0.1"
        authorityId = "fixture:offline-publication"
        repositoryRef = $input.context.repositoryRef
        branchRef = $input.context.branchRef
        subjectRef = $input.context.subjectRef
        headSha = $head
        workorderDigest = $input.context.workorderDigest
        policyDigest = $input.context.policyDigest
        action = "push"
        issuer = "urn:threshold:actor:authority:11111111-1111-4111-8111-111111111111"
        issuedAt = "2026-11-04T23:59:00.000Z"
        expiresAt = "2026-11-05T00:01:00.000Z"
        consumptionId = "fixture:unused-consumption"
        nonClaims = @("one-shot authority is not reusable", "offline fixture only; no effect is executed")
    }
    $positiveJson = $input | ConvertTo-Json -Depth 100 -Compress
    $positiveDigest = Get-CanonicalPublicationInputDigest -CliPath $cliPath -InputJson $positiveJson
    [System.IO.File]::WriteAllText($inputPath, $positiveJson, [System.Text.UTF8Encoding]::new($false))
    $positiveOutput = @(& node $cliPath validate-publication-authority --input $inputPath)
    $positiveCode = $LASTEXITCODE
    $positiveResult = ConvertFrom-SingleJsonDocument -Text ($positiveOutput -join "`n")
    Assert-CorePublicationAuthorityResult -Result $positiveResult -ExpectedHead $head -ExpectedInputDigest $positiveDigest
    if ($positiveCode -ne 0 -or $positiveResult.valid -ne $true -or $positiveResult.effectDecisions.publication.allowed -ne $true) {
        throw "Offline fixture's exact publication input was not accepted by the canonical producer and typed consumer"
    }
    foreach ($effect in @("localExperiment", "localCommit", "merge", "reviewDecision")) {
        if ($positiveResult.effectDecisions.$effect.allowed -ne $false) { throw "Publication fixture granted another write effect: $effect" }
    }
    Write-Host "publicationCoreContract=passed_positive_and_denied"
    Write-Host "runtimeAuthority=NONE"
    Write-Host "executionAuthorized=false"
}
finally { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue }
$global:LASTEXITCODE = 0 # The denied canonical result above is the expected outcome.
