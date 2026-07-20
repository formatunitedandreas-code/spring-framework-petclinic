[CmdletBinding()]
param(
    [string] $BaseRef = "main",
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [switch] $PublicationPreflight,
    [string] $AuthorityPath = "threshold/runtime/authority/merge-authority.json",
    [string] $ConsumedAuthorityPath = "threshold/runtime/authority/consumed-authorities.json",
    [string] $ThresholdCorePath = $env:THRESHOLD_CORE_PATH,
    [string] $ReviewHead = "",
    [string] $ReviewDecision = "",
    [int] $OpenP1P2Count = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")
. (Join-Path $PSScriptRoot "lib/semantic-workflow.ps1")

$AllowedValidationResults = @(
    "BUILD SUCCESS",
    "BUILD FAILURE",
    "TEST_FAILURE",
    "SKIPPED_BY_LEASE_INVOCATION"
)

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name'" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function ConvertTo-RepoPath {
    param([string] $Path)

    $root = (git rev-parse --show-toplevel).Trim()
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($fullRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        return ($relative -replace "\\", "/")
    }
    return ($Path -replace "\\", "/")
}

function Test-LeasePath {
    param([string] $Path)

    $normalized = $Path -replace "\\", "/"
    return $normalized -like "threshold/leases/*"
}

function Test-ProductPath {
    param([string] $Path)

    $normalized = $Path -replace "\\", "/"
    return (
        $normalized -like "src/main/*" -or
        $normalized -like "src/test/*" -or
        $normalized -eq "pom.xml"
    )
}

function Assert-ChangedFilesMatchReceipt {
    param([string] $Commit, [pscustomobject] $Receipt)

    $actual = @(git diff-tree --no-commit-id --name-only -r $Commit | Sort-Object)
    $claimed = @(
        $Receipt.changedFiles | ForEach-Object {
            if ($_ -is [string]) {
                [string] $_
            }
            elseif ($null -ne $_.path) {
                [string] $_.path
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object
    )
    if ($claimed.Count -eq 0) {
        throw "Receipt for $Commit has no changedFiles paths."
    }
    if (($actual -join "`n") -ne ($claimed -join "`n")) {
        throw "Receipt changedFiles mismatch for $Commit. actual=[$($actual -join ', ')] claimed=[$($claimed -join ', ')]"
    }
}

function Get-CommitPathBlobSha256 {
    param([string] $Commit, [string] $Path)

    $spec = "$Commit`:$Path"
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "git"
    $argumentListProperty = $processInfo.GetType().GetProperty("ArgumentList")
    if ($null -ne $argumentListProperty) {
        [void] $processInfo.ArgumentList.Add("cat-file")
        [void] $processInfo.ArgumentList.Add("blob")
        [void] $processInfo.ArgumentList.Add($spec)
    }
    else {
        $escapedSpec = $spec.Replace('"', '\"')
        $processInfo.Arguments = "cat-file blob `"$escapedSpec`""
    }
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $buffer = [byte[]]::new(8192)
    try {
        while (($read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void] $sha256.TransformBlock($buffer, 0, $read, $null, 0)
        }
        [void] $sha256.TransformFinalBlock($buffer, 0, 0)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Failed to hash $Path at commit $Commit. $stderr"
        }
        return ([System.BitConverter]::ToString($sha256.Hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $process.Dispose()
    }
}

function Get-ReceiptCommit {
    param([string] $ReceiptPath)

    $receiptCommits = @(git log --format=%H "origin/${BaseRef}..HEAD" -- $ReceiptPath)
    if ($LASTEXITCODE -ne 0 -or $receiptCommits.Count -eq 0 -or [string]::IsNullOrWhiteSpace($receiptCommits[0])) {
        throw "Could not determine receipt commit for $ReceiptPath."
    }
    return ([string] $receiptCommits[0]).Trim()
}

function Assert-ReceiptLeaseDigestMatchesReceiptCommit {
    param([string] $ReceiptPath, [pscustomobject] $Receipt)

    if (-not $Receipt.leaseDigest) {
        throw "Receipt is missing leaseDigest: $ReceiptPath"
    }
    $receiptCommit = Get-ReceiptCommit -ReceiptPath $ReceiptPath
    $receiptLeaseDigest = Get-CommitPathBlobSha256 -Commit $receiptCommit -Path $LeasePath
    if ([string] $Receipt.leaseDigest -ne $receiptLeaseDigest) {
        throw "Receipt leaseDigest mismatch for $ReceiptPath at receipt commit $receiptCommit."
    }
}

function Get-TextSha256 {
    param([string] $Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-ReceiptValidation {
    param([string] $ReceiptPath, [pscustomobject] $Receipt, [string] $ExpectedHead = "")

    if (-not $Receipt.validation) { throw "Receipt is missing validation object: $ReceiptPath" }
    if ($AllowedValidationResults -notcontains [string]$Receipt.validation.result) {
        throw "Receipt has undefined validation result '$($Receipt.validation.result)': $ReceiptPath"
    }
    foreach ($field in @("testedHead", "command", "testsRun", "failures", "errors", "profile", "executedAt", "resultDigest", "branchFinalValidationPassed", "validationReportRef")) {
        if ($null -eq $Receipt.validation.PSObject.Properties[$field]) {
            throw "Receipt validation is missing ${field}: $ReceiptPath"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHead) -and [string]$Receipt.validation.testedHead -ne $ExpectedHead) {
        throw "Receipt validation testedHead mismatch for $ReceiptPath. expected=$ExpectedHead actual=$($Receipt.validation.testedHead)"
    }
}

function Get-AggregateProductCommits {
    param([pscustomobject] $AggregateReceipt)

    if ($null -eq $AggregateReceipt.PSObject.Properties["productCommits"]) { return @() }
    return @($AggregateReceipt.productCommits | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-AggregateReceipt {
    param([string] $Path, [pscustomobject] $AggregateReceipt, [bool] $BranchFinalValidationRequired)

    foreach ($field in @("schemaVersion", "runId", "sourceHead", "finalHead", "terminalState", "productCommits", "changedProductFiles", "receiptCount", "nonClaims")) {
        if ($null -eq $AggregateReceipt.PSObject.Properties[$field]) {
            throw "Aggregate receipt is missing ${field}: $Path"
        }
    }
    if ($BranchFinalValidationRequired) {
        if ($null -eq $AggregateReceipt.PSObject.Properties["branchFinalValidationPassed"] -or $AggregateReceipt.branchFinalValidationPassed -ne $true) {
            throw "Aggregate receipt is missing branch final validation pass: $Path"
        }
    }
}

function Get-ConsumedAuthorityIds {
    param([string] $Path)

    if (-not (Test-Path $Path)) { return @() }
    $json = Get-Content $Path -Raw | ConvertFrom-Json
    if ($json.PSObject.Properties["consumedAuthorityIds"]) {
        return @($json.consumedAuthorityIds | ForEach-Object { [string]$_ })
    }
    if ($json.PSObject.Properties["consumedConsumptionIds"]) {
        return @($json.consumedConsumptionIds | ForEach-Object { [string]$_ })
    }
    return @()
}

function Get-PolicyDigest {
    $policyPaths = @(
        "threshold/policies/file-economy-v0.1.yaml",
        "threshold/policies/semantic-twin-v0.1.yaml",
        "threshold/policies/senior-refactoring-admission-v0.1.yaml",
        "threshold/policies/target-twin-v0.1.yaml"
    ) | Where-Object { Test-Path $_ }
    $content = @($policyPaths | Sort-Object | ForEach-Object { "$_`n$(Get-Content $_ -Raw)" }) -join "`n---threshold-policy---`n"
    return Get-TextSha256 -Value $content
}

function Get-PreflightSubjectDigest {
    param([string[]] $ChangedPaths, [string] $Head)
    return Get-TextSha256 -Value ((@($Head) + @($ChangedPaths | Sort-Object)) -join "`n")
}

function Get-JsonPropertyOrNull {
    param([object] $Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $null
}

function Test-JsonProperty {
    param([object] $Object, [string] $Name)

    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $Object.PSObject.Properties.Name -contains $Name
}

function Assert-AllowedJsonProperties {
    param([object] $Object, [string[]] $AllowedNames, [string] $Context)

    foreach ($property in @($Object.PSObject.Properties.Name)) {
        if ($AllowedNames -notcontains [string]$property) {
            throw "stop_authority_validator_unavailable=${Context}_unknown_field=$property"
        }
    }
}

function Assert-StringArray {
    param([object] $Object, [string] $Name, [string] $Context)

    if (-not (Test-JsonProperty -Object $Object -Name $Name)) {
        throw "stop_authority_validator_unavailable=${Context}_missing"
    }
    $Value = if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name]
    }
    else {
        $Object.PSObject.Properties[$Name].Value
    }
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            throw "stop_authority_validator_unavailable=${Context}_invalid"
        }
        return
    }
    foreach ($item in @($Value)) {
        if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace([string]$item)) {
            throw "stop_authority_validator_unavailable=${Context}_invalid"
        }
    }
}

function Get-PublicationStopFromFailedConstraints {
    param([string[]] $FailedConstraintIds)

    if ($FailedConstraintIds -contains "publication-branch-binding") { return "stop_authority_mismatch=branchRef" }
    if ($FailedConstraintIds -contains "publication-head-binding") { return "stop_authority_mismatch=headSha" }
    if ($FailedConstraintIds -contains "publication-authority-expiry") { return "stop_authority_expired" }
    if ($FailedConstraintIds -contains "publication-authority-unconsumed" -or $FailedConstraintIds -contains "publication-authority-consumption-id-unused") {
        return "stop_authority_consumed"
    }
    if ($FailedConstraintIds -contains "publication-authority-present") { return "stop_authority_missing" }
    return "stop_authority_invalid"
}

function ConvertFrom-SingleJsonDocument {
    param([string] $Text)

    if ($Text.Trim() -match "(?s)^\s*\{.*\}\s*\{") {
        throw "stop_authority_validator_unavailable=canonical validator emitted multiple JSON documents"
    }
    try {
        $documents = @($Text | ConvertFrom-Json)
    }
    catch {
        throw "stop_authority_validator_unavailable=canonical validator emitted invalid JSON"
    }
    if ($documents.Count -ne 1) {
        throw "stop_authority_validator_unavailable=canonical validator emitted multiple JSON documents"
    }
    return $documents[0]
}

function Assert-CorePublicationAuthorityResult {
    param([object] $Result, [string] $ExpectedHead)

    Assert-AllowedJsonProperties -Object $Result -AllowedNames @(
        "valid",
        "evaluatedHead",
        "inputDigest",
        "effectDecisions",
        "failedConstraintIds",
        "decision",
        "reasonCodes",
        "constraintOutcomes",
        "authorityDigest",
        "policyDigest",
        "nonClaims"
    ) -Context "publication_authority_result"

    if (-not ((Get-JsonPropertyOrNull -Object $Result -Name "valid") -is [bool])) {
        throw "stop_authority_validator_unavailable=publication_authority_result_valid_missing"
    }
    $evaluatedHead = [string](Get-JsonPropertyOrNull -Object $Result -Name "evaluatedHead")
    if ([string]::IsNullOrWhiteSpace($evaluatedHead)) {
        throw "stop_authority_validator_unavailable=publication_authority_result_evaluatedHead_missing"
    }
    if ($evaluatedHead -ne $ExpectedHead) {
        throw "stop_authority_toctou=evaluatedHead_mismatch expected=$ExpectedHead actual=$evaluatedHead"
    }
    $inputDigest = [string](Get-JsonPropertyOrNull -Object $Result -Name "inputDigest")
    if ([string]::IsNullOrWhiteSpace($inputDigest)) {
        throw "stop_authority_validator_unavailable=publication_authority_result_inputDigest_missing"
    }

    Assert-StringArray -Object $Result -Name "failedConstraintIds" -Context "publication_authority_result_failedConstraintIds"

    $effectDecisions = Get-JsonPropertyOrNull -Object $Result -Name "effectDecisions"
    if ($null -eq $effectDecisions) {
        throw "stop_authority_validator_unavailable=publication_authority_result_effectDecisions_missing"
    }
    Assert-AllowedJsonProperties -Object $effectDecisions -AllowedNames @(
        "observe",
        "localExperiment",
        "shadowIntegration",
        "publication",
        "merge"
    ) -Context "publication_authority_result_effectDecisions"

    $publicationDecision = Get-JsonPropertyOrNull -Object $effectDecisions -Name "publication"
    if ($null -eq $publicationDecision) {
        throw "stop_authority_validator_unavailable=publication_authority_result_publication_decision_missing"
    }
    Assert-AllowedJsonProperties -Object $publicationDecision -AllowedNames @(
        "effect",
        "allowed",
        "disposition",
        "failedConstraintIds"
    ) -Context "publication_authority_result_publication_decision"
    if (-not ((Get-JsonPropertyOrNull -Object $publicationDecision -Name "allowed") -is [bool])) {
        throw "stop_authority_validator_unavailable=publication_authority_result_publication_allowed_missing"
    }
    Assert-StringArray -Object $publicationDecision -Name "failedConstraintIds" -Context "publication_authority_result_publication_failedConstraintIds"
}

function Invoke-CanonicalPublicationAuthorityValidation {
    param(
        [string] $Path,
        [string] $RepositoryRef,
        [string] $Branch,
        [string] $SubjectRef,
        [string] $Head,
        [string] $WorkorderDigest,
        [string] $PolicyDigest
    )

    if (-not (Test-Path $Path)) {
        throw "stop_authority_missing=one-shot merge authority required for publication preflight"
    }

    if ([string]::IsNullOrWhiteSpace($ThresholdCorePath)) {
        throw "stop_authority_validator_unavailable=ThresholdCorePath or THRESHOLD_CORE_PATH is required"
    }
    $coreRoot = [System.IO.Path]::GetFullPath($ThresholdCorePath)
    $cliPath = Join-Path $coreRoot "packages/refactoring-governor/dist/cli/thresholdRefactoringCliV0_1.js"
    if (-not (Test-Path $cliPath)) {
        throw "stop_authority_validator_unavailable=canonical validator CLI not found at ThresholdCorePath"
    }

    $runtimeRoot = "threshold/runtime/authority-validation"
    if (-not (Test-Path $runtimeRoot)) { New-Item -ItemType Directory -Path $runtimeRoot | Out-Null }
    $inputPath = Join-Path $runtimeRoot "publication-authority-input.json"
    $resultPath = Join-Path $runtimeRoot "publication-authority-result.json"

    $input = [ordered]@{
        authority = (Get-Content $Path -Raw | ConvertFrom-Json)
        context = [ordered]@{
            repositoryRef = $RepositoryRef
            branchRef = $Branch
            subjectRef = $SubjectRef
            headSha = $Head
            workorderDigest = $WorkorderDigest
            policyDigest = $PolicyDigest
            action = "merge"
            now = (Get-Date).ToUniversalTime().ToString("o")
            consumedConsumptionIds = @(Get-ConsumedAuthorityIds -Path $ConsumedAuthorityPath)
        }
        verificationRef = "test-pr-governance:structural"
        reviewRef = "review:$ReviewDecision@$ReviewHead"
    }
    $input | ConvertTo-Json -Depth 20 | Set-Content -Path $inputPath -Encoding UTF8

    $preValidationHead = (& git rev-parse HEAD).Trim()
    if ($preValidationHead -ne $Head) {
        throw "stop_authority_toctou=prevalidation_head_mismatch expected=$Head actual=$preValidationHead"
    }
    $preValidationBranch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($preValidationBranch)) {
        throw "stop_authority_toctou=prevalidation_detached_head"
    }
    $preValidationTree = (& git rev-parse "$preValidationHead^{tree}").Trim()
    $output = @(& node $cliPath validate-publication-authority --input $inputPath 2>&1)
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $outputText | Set-Content -Path $resultPath -Encoding UTF8
    $result = ConvertFrom-SingleJsonDocument -Text $outputText
    Assert-CorePublicationAuthorityResult -Result $result -ExpectedHead $preValidationHead
    $postValidationHead = (& git rev-parse HEAD).Trim()
    $postValidationBranch = (& git branch --show-current).Trim()
    $postValidationTree = (& git rev-parse "$postValidationHead^{tree}").Trim()
    if ($postValidationHead -ne $preValidationHead) {
        throw "stop_authority_toctou=postvalidation_head_changed pre=$preValidationHead post=$postValidationHead"
    }
    if ([string]::IsNullOrWhiteSpace($postValidationBranch) -or $postValidationBranch -ne $preValidationBranch) {
        throw "stop_authority_toctou=postvalidation_branch_changed pre=$preValidationBranch post=$postValidationBranch"
    }
    if ($postValidationTree -ne $preValidationTree) {
        throw "stop_authority_toctou=postvalidation_tree_changed pre=$preValidationTree post=$postValidationTree"
    }
    if ($postValidationHead -ne [string]$result.evaluatedHead) {
        throw "stop_authority_toctou=postvalidation_evaluatedHead_mismatch post=$postValidationHead evaluated=$($result.evaluatedHead)"
    }

    $publicationDecision = $result.effectDecisions.publication
    $publicationFailedConstraintIds = @($publicationDecision.failedConstraintIds | ForEach-Object { [string]$_ })
    Write-Host "publicationAuthorityValidator=threshold-core"
    Write-Host "publicationAuthorityEvaluatedHead=$($result.evaluatedHead)"
    Write-Host "publicationAuthorityInputDigest=$($result.inputDigest)"
    Write-Host "publicationAuthorityPublicationAllowed=$($publicationDecision.allowed.ToString().ToLowerInvariant())"
    Write-Host "publicationAuthorityFailedConstraintIds=$((@($result.failedConstraintIds) | Sort-Object) -join ',')"
    if ($result.PSObject.Properties.Name -contains "reasonCodes") {
        Write-Host "publicationAuthorityReasonCodes=$((@($result.reasonCodes) | Sort-Object) -join ',')"
    }
    if ($result.valid -ne $true -or $publicationDecision.allowed -ne $true) {
        throw (Get-PublicationStopFromFailedConstraints -FailedConstraintIds $publicationFailedConstraintIds)
    }
}

function Assert-PublicationPreflight {
    param([string[]] $ChangedPaths)

    $head = (& git rev-parse HEAD).Trim()
    $branch = (& git branch --show-current).Trim()
    $remoteUrl = (& git remote get-url origin).Trim()
    $repositoryRef = if ($remoteUrl -match "github.com[:/](.+?)(\.git)?$") { $Matches[1] -replace "\.git$", "" } else { $remoteUrl }
    $subjectRef = "pull-request:$branch->$BaseRef"
    $policyDigest = Get-PolicyDigest
    $subjectDigest = Get-PreflightSubjectDigest -ChangedPaths $ChangedPaths -Head $head

    if ([string]::IsNullOrWhiteSpace($ReviewHead)) {
        throw "stop_review_missing=publication preflight requires review on final head"
    }
    if ($ReviewHead -ne $head) {
        throw "stop_review_stale_head"
    }
    if ($ReviewDecision -ne "APPROVED") {
        throw "stop_review_missing=publication preflight requires independent approval"
    }
    if ($OpenP1P2Count -gt 0) {
        throw "stop_open_p1_p2_findings=$OpenP1P2Count"
    }

    Invoke-CanonicalPublicationAuthorityValidation `
        -Path $AuthorityPath `
        -RepositoryRef $repositoryRef `
        -Branch $branch `
        -SubjectRef $subjectRef `
        -Head $head `
        -WorkorderDigest $subjectDigest `
        -PolicyDigest $policyDigest

    $actionHead = (& git rev-parse HEAD).Trim()
    $actionBranch = (& git branch --show-current).Trim()
    if ($actionHead -ne $head) {
        throw "stop_authority_toctou=action_head_mismatch expected=$head actual=$actionHead"
    }
    if ([string]::IsNullOrWhiteSpace($actionBranch) -or $actionBranch -ne $branch) {
        throw "stop_authority_toctou=action_branch_mismatch expected=$branch actual=$actionBranch"
    }
    Write-Host "publicationActionHead=$actionHead"
    Write-Host "publicationValidatedPushRef=git push origin ${actionHead}:refs/heads/<targetBranch>"
    Write-Host "publicationPreflight=passed"
}

if (-not (Test-Path $LeasePath)) {
    throw "Missing Threshold lease: $LeasePath"
}
if (-not (Test-Path $StatePath)) {
    throw "Missing lease state file: $StatePath"
}

$leaseLines = Get-Content $LeasePath
$allowedPaths = Get-ThresholdLeaseList -Lines $leaseLines -Name "allowedPaths"
$forbiddenPaths = Get-ThresholdLeaseList -Lines $leaseLines -Name "forbiddenPaths"
$expectedBaseRef = Get-LeaseScalar $leaseLines "baseRef"
$mergeAllowed = Get-LeaseScalar $leaseLines "mergeAllowed"
$forbiddenActions = @(Get-ThresholdLeaseList -Lines $leaseLines -Name "forbiddenActions")
if ($BaseRef -ne $expectedBaseRef.Replace("origin/", "")) {
    throw "PR base ref '$BaseRef' does not match threshold baseRef '$expectedBaseRef'."
}

$changedPaths = @(git diff --name-only "origin/${BaseRef}...HEAD")
if ($changedPaths.Count -eq 0) { throw "No changed paths detected for the pull request." }

$publicationAuthoritySatisfied = $false
if ($PublicationPreflight.IsPresent) {
    Assert-PublicationPreflight -ChangedPaths $changedPaths
    $publicationAuthoritySatisfied = $true
}

$runEvidencePaths = @($changedPaths | Where-Object { $_ -like "threshold/runs/*" })
Assert-ThresholdSemanticEvidenceFileEconomy -BaseRef "origin/${BaseRef}" -RequireCompleteRunEvidence:($runEvidencePaths.Count -gt 0)

$governancePolicyPaths = @($changedPaths | Where-Object { Test-ThresholdGovernancePolicyPath -Path $_ })
$leasePaths = @($changedPaths | Where-Object { Test-LeasePath $_ })
$productPaths = @($changedPaths | Where-Object { Test-ProductPath $_ })
if ($governancePolicyPaths.Count -gt 0 -and $productPaths.Count -gt 0) {
    throw "PR mixes governance policy and product paths; split into separate governed changes."
}

$requiresMergeAuthority = $governancePolicyPaths.Count -gt 0 -or ($leasePaths.Count -gt 0 -and $productPaths.Count -eq 0)
$mergeAuthoritySatisfied = $publicationAuthoritySatisfied
if ($mergeAllowed -eq "true") {
    Write-Host "legacyLeaseMergeAllowed=ignored_for_publication_authority"
}
if ($forbiddenActions -contains "merge") {
    Write-Host "leaseForbiddenMergeAction=structural_hold_only"
}

foreach ($path in $changedPaths) {
    $isAllowed = $false
    foreach ($pattern in $allowedPaths) {
        if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
            $isAllowed = $true
            break
        }
    }
    if (-not $isAllowed -and -not (Test-ThresholdGovernancePath -Path $path)) {
        throw "Changed path is outside Threshold lease allowlist: $path"
    }
    foreach ($pattern in $forbiddenPaths) {
        if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
            throw "Changed path is forbidden by Threshold lease: $path"
        }
    }
}

$receiptPaths = @(Get-ChildItem threshold/receipts -Filter *.json -ErrorAction SilentlyContinue)
if ($receiptPaths.Count -eq 0) { throw "Missing Threshold receipt under threshold/receipts/*.json" }

$receiptByCommit = @{}
foreach ($receiptPath in $receiptPaths) {
    $receipt = Get-Content $receiptPath.FullName -Raw | ConvertFrom-Json
    $repoReceiptPath = ConvertTo-RepoPath -Path $receiptPath.FullName
    if ($receipt.PSObject.Properties["commitHash"] -and $receipt.commitHash) {
        $receiptByCommit[[string] $receipt.commitHash] = @{ path = $repoReceiptPath; receipt = $receipt }
    }
    elseif ($receipt.PSObject.Properties["sourceCommit"] -and $receipt.sourceCommit) {
        $receiptByCommit[[string] $receipt.sourceCommit] = @{ path = $repoReceiptPath; receipt = $receipt }
    }
}

$aggregateReceiptByCommit = @{}
$aggregateReceiptPaths = @(Get-ChildItem threshold/runs -Recurse -Filter aggregate-receipt.json -ErrorAction SilentlyContinue)
foreach ($aggregatePath in $aggregateReceiptPaths) {
    $repoAggregatePath = ConvertTo-RepoPath -Path $aggregatePath.FullName
    $aggregate = Get-Content $aggregatePath.FullName -Raw | ConvertFrom-Json
    Assert-AggregateReceipt -Path $repoAggregatePath -AggregateReceipt $aggregate -BranchFinalValidationRequired:($productPaths.Count -gt 0)
    foreach ($commit in Get-AggregateProductCommits -AggregateReceipt $aggregate) {
        $aggregateReceiptByCommit[$commit] = @{ path = $repoAggregatePath; receipt = $aggregate }
    }
}

$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if (-not $state.invocationId) { throw "Lease state is missing invocationId." }
if (-not $state.currentHead) { throw "Lease state is missing currentHead." }
if (-not $state.remainingBudget) { throw "Lease state is missing remainingBudget." }

$prCommits = @(git rev-list --reverse "origin/${BaseRef}..HEAD")
if ($prCommits.Count -eq 0) { throw "No PR commits detected." }

$sourceCommitCount = 0
foreach ($commit in $prCommits) {
    $commitPaths = @(git diff-tree --no-commit-id --name-only -r $commit)
    if ($commitPaths.Count -eq 0) { continue }

    $governanceOnly = $true
    foreach ($path in $commitPaths) {
        if (-not (Test-ThresholdGovernancePath -Path $path)) {
            $governanceOnly = $false
            break
        }
    }
    if ($governanceOnly) {
        Write-Host "Governance-only commit does not require self-referential receipt: $commit"
        continue
    }

    $sourceCommitCount += 1
    if (-not $receiptByCommit.ContainsKey($commit) -and -not $aggregateReceiptByCommit.ContainsKey($commit)) {
        throw "Source commit without corresponding Threshold receipt: $commit"
    }
    if ($aggregateReceiptByCommit.ContainsKey($commit)) {
        Write-Host "Source commit covered by aggregate Threshold receipt: $commit"
        continue
    }

    $entry = $receiptByCommit[$commit]
    $receipt = $entry.receipt
    if (-not $receipt.candidateId -and -not $receipt.batchId) { throw "Receipt is missing candidateId/batchId: $($entry.path)" }
    if (-not $receipt.baseHead) { throw "Receipt is missing baseHead: $($entry.path)" }
    if (-not $receipt.validation -or -not $receipt.validation.result) { throw "Receipt is missing validation result: $($entry.path)" }
    if (-not $receipt.nonClaims -or $receipt.nonClaims.Count -eq 0) { throw "Receipt is missing nonClaims: $($entry.path)" }
    Assert-ReceiptValidation -ReceiptPath $entry.path -Receipt $receipt -ExpectedHead $commit
    Assert-ReceiptLeaseDigestMatchesReceiptCommit -ReceiptPath $entry.path -Receipt $receipt
    Assert-ChangedFilesMatchReceipt -Commit $commit -Receipt $receipt
}

if ($sourceCommitCount -eq 0 -and $productPaths.Count -gt 0) {
    throw "No source commit detected in PR range."
}

Write-Host "sourceCommitReceiptCoverage=complete"
Write-Host "governanceStructureValid=true"
Write-Host "publicationAuthoritySatisfied=$($publicationAuthoritySatisfied.ToString().ToLowerInvariant())"
Write-Host "thresholdGovernanceLabelRequired=$($requiresMergeAuthority.ToString().ToLowerInvariant())"
Write-Host "thresholdMergeAuthorityRequired=$($requiresMergeAuthority.ToString().ToLowerInvariant())"
Write-Host "thresholdMergeAuthoritySatisfied=$($mergeAuthoritySatisfied.ToString().ToLowerInvariant())"
Write-Host "Threshold governance passed"
