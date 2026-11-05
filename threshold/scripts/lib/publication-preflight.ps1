function Get-GitFirstLine {
    param([string[]] $GitArgs)

    $output = @(& git @GitArgs)
    if ($output.Count -eq 0 -or $null -eq $output[0]) { return "" }
    return ([string]$output[0]).Trim()
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

function Get-ConsumedAuthorityIds {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "stop_consumption_state_unknown=missing_ledger"
    }
    try { $json = ConvertFrom-SingleJsonDocument -Text (Get-Content -LiteralPath $Path -Raw) }
    catch { throw "stop_consumption_state_unknown=malformed_ledger" }
    if (Test-JsonProperty -Object $json -Name "consumedAuthorityIds") {
        throw "stop_consumption_state_unknown=authority_ids_are_not_consumption_ids"
    }
    try {
        Assert-AllowedJsonProperties -Object $json -AllowedNames @("schemaVersion", "consumedConsumptionIds") -Context "consumption_ledger"
        Assert-StringArray -Object $json -Name "consumedConsumptionIds" -Context "consumption_ledger"
    }
    catch { throw "stop_consumption_state_unknown=invalid_consumption_ids" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($id in $json.consumedConsumptionIds) {
        if (-not $seen.Add($id)) { throw "stop_consumption_state_unknown=duplicate_consumption_id" }
    }
    return @($json.consumedConsumptionIds)
}

function Get-PolicyDigest {
    $policyPaths = @(
        "threshold/policies/file-economy-v0.1.yaml",
        "threshold/policies/semantic-twin-v0.1.yaml",
        "threshold/policies/senior-refactoring-admission-v0.1.yaml",
        "threshold/policies/target-twin-v0.1.yaml"
    )
    foreach ($policyPath in $policyPaths) {
        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { throw "stop_authority_missing=policy:$policyPath" }
    }
    $content = @($policyPaths | Sort-Object | ForEach-Object { "$_`n$(Get-Content $_ -Raw)" }) -join "`n---threshold-policy---`n"
    return "sha256:" + (Get-TextSha256 -Value $content)
}

function Get-PreflightSubjectDigest {
    param([string[]] $ChangedPaths, [string] $Head)
    return "sha256:" + (Get-TextSha256 -Value ((@($Head) + @($ChangedPaths | Sort-Object)) -join "`n"))
}

function Get-JsonPropertyOrNull {
    param([object] $Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    if (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -ccontains $Name) {
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
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name }) -ccontains $Name
}

function Assert-AllowedJsonProperties {
    param([object] $Object, [string[]] $AllowedNames, [string] $Context)

    foreach ($property in @($Object.PSObject.Properties | ForEach-Object { $_.Name })) {
        if ($AllowedNames -cnotcontains [string]$property) {
            throw "stop_authority_validator_unavailable=${Context}_unknown_field=$property"
        }
    }
}

function Assert-StringArray {
    param([object] $Object, [string] $Name, [string] $Context)
    if (-not (Test-JsonProperty -Object $Object -Name $Name)) {
        throw "stop_authority_validator_unavailable=${Context}_missing"
    }
    if ($Object -is [System.Collections.IDictionary]) { $value = $Object[$Name] }
    else { $value = $Object.PSObject.Properties[$Name].Value }
    if (-not ($value -is [System.Array])) {
        throw "stop_authority_validator_unavailable=${Context}_invalid_array"
    }
    foreach ($item in $value) {
        if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) {
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
    if ($FailedConstraintIds -contains "publication-action-binding" -or $FailedConstraintIds -contains "one-shot-authority-action-binding") { return "stop_authority_mismatch=action" }
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
    if ($null -eq $documents[0] -or -not ($documents[0] -is [pscustomobject])) {
        throw "stop_authority_validator_unavailable=canonical validator must emit one JSON object"
    }
    return $documents[0]
}

function Assert-CorePublicationAuthorityResult {
    param([object] $Result, [string] $ExpectedHead, [string] $ExpectedInputDigest)

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

    if ($inputDigest -cne $ExpectedInputDigest) {
        throw "stop_authority_toctou=inputDigest_mismatch"
    }

    Assert-StringArray -Object $Result -Name "failedConstraintIds" -Context "publication_authority_result_failedConstraintIds"

    $effectDecisions = Get-JsonPropertyOrNull -Object $Result -Name "effectDecisions"
    if ($null -eq $effectDecisions) {
        throw "stop_authority_validator_unavailable=publication_authority_result_effectDecisions_missing"
    }
    Assert-AllowedJsonProperties -Object $effectDecisions -AllowedNames @(
        "observe",
        "localExperiment",
        "localCommit",
        "reviewDecision",
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
    if ((Get-JsonPropertyOrNull -Object $publicationDecision -Name "effect") -cne "publication") {
        throw "stop_authority_validator_unavailable=publication_effect_mismatch"
    }
    $allowed = $publicationDecision.allowed
    $disposition = [string](Get-JsonPropertyOrNull -Object $publicationDecision -Name "disposition")
    if (($allowed -and $disposition -cne "allowed") -or
        (-not $allowed -and $disposition -cnotin @("stop_no_action", "shadow_only", "blocked"))) {
        throw "stop_authority_validator_unavailable=publication_disposition_mismatch"
    }
    if ($allowed -and (@($publicationDecision.failedConstraintIds).Count -gt 0 -or @($Result.failedConstraintIds).Count -gt 0)) {
        throw "stop_authority_validator_unavailable=publication_allowed_with_failed_constraints"
    }

}

function Get-CanonicalPublicationInputDigest {
    param([string] $CliPath, [string] $InputJson)
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command node -ErrorAction Stop).Source
    $start.Arguments = '"' + $CliPath + '" digest-publication-authority-input --stdin'
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "stop_authority_validator_unavailable=digest_start_failed" }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($InputJson)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($errorOutput)) {
            throw "stop_authority_validator_unavailable=canonical_input_digest_failed"
        }
        $result = ConvertFrom-SingleJsonDocument -Text $output
        Assert-AllowedJsonProperties -Object $result -AllowedNames @("inputDigest") -Context "input_digest_result"
        $digest = [string](Get-JsonPropertyOrNull -Object $result -Name "inputDigest")
        if ($digest -cnotmatch "^[0-9a-f]{64}$") {
            throw "stop_authority_validator_unavailable=canonical_input_digest_invalid"
        }
        return $digest
    }
    finally { $process.Dispose() }
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
        throw "stop_authority_missing=one-shot publication authority required for publication preflight"
    }

    if ([string]::IsNullOrWhiteSpace($ThresholdCorePath)) {
        throw "stop_authority_validator_unavailable=ThresholdCorePath or THRESHOLD_CORE_PATH is required"
    }
    $coreRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ThresholdCorePath)
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
            action = "push"
            now = (Get-Date).ToUniversalTime().ToString("o")
            consumedConsumptionIds = @(Get-ConsumedAuthorityIds -Path $ConsumedAuthorityPath)
        }
        verificationRef = "test-pr-governance:structural"
        reviewRef = "review:$ReviewDecision@$ReviewHead"
    }
    $inputJson = $input | ConvertTo-Json -Depth 100 -Compress
    $expectedInputDigest = Get-CanonicalPublicationInputDigest -CliPath $cliPath -InputJson $inputJson
    [System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inputPath), $inputJson, [System.Text.UTF8Encoding]::new($false))

    $preValidationHead = (& git rev-parse HEAD).Trim()
    if ($preValidationHead -ne $Head) {
        throw "stop_authority_toctou=prevalidation_head_mismatch expected=$Head actual=$preValidationHead"
    }
    $preValidationBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
    if ([string]::IsNullOrWhiteSpace($preValidationBranch)) {
        throw "stop_authority_toctou=prevalidation_detached_head"
    }
    $preValidationTree = (& git rev-parse "$preValidationHead^{tree}").Trim()
    $output = @(& node $cliPath validate-publication-authority --input $inputPath 2>&1)
    $validatorExitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $outputText | Set-Content -Path $resultPath -Encoding UTF8
    $result = ConvertFrom-SingleJsonDocument -Text $outputText
    Assert-CorePublicationAuthorityResult -Result $result -ExpectedHead $preValidationHead -ExpectedInputDigest $expectedInputDigest
    $postValidationHead = (& git rev-parse HEAD).Trim()
    $postValidationBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
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

    if ($validatorExitCode -ne 0 -and $result.valid -eq $true) {
        throw "stop_authority_validator_unavailable=validator_failed_with_allow_result"
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
    $branch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
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
    if ($OpenP1P2Count -ne 0) {
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
    $actionBranch = Get-GitFirstLine -GitArgs @("branch", "--show-current")
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
