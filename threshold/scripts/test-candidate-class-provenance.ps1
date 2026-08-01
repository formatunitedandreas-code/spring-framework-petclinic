[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")
$thresholdScriptRoot = $PSScriptRoot
$repoRoot = Split-Path (Split-Path $thresholdScriptRoot -Parent) -Parent

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "Expected true: $Name" }
    Write-Host "passed=$Name"
}

function Assert-False {
    param([bool] $Condition, [string] $Name)
    if ($Condition) { throw "Expected false: $Name" }
    Write-Host "passed=$Name"
}

function Write-CanaryFile {
    param([string] $Path, [string[]] $Lines)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $dir).Path + [System.IO.Path]::DirectorySeparatorChar + (Split-Path $Path -Leaf), ([string]::Join("`n", $Lines) + "`n"), [System.Text.UTF8Encoding]::new($false))
}

$originalLocation = Get-Location
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-candidate-provenance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Set-Location $tempRoot
    & git init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    & git config user.email "threshold-canary@example.invalid"
    & git config user.name "Threshold Canary"

    $javaPath = "src/main/java/org/example/PetTypeFormatter.java"
    Write-CanaryFile -Path $javaPath -Lines @(
        "package org.example;",
        "",
        "import java.util.Locale;",
        "",
        "class PetTypeFormatter {",
        "    public String print(Locale locale) {",
        "        return locale.toLanguageTag();",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Initial canary source" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
    $baseHead = (& git rev-parse HEAD).Trim()

    Write-CanaryFile -Path $javaPath -Lines @(
        "package org.example;",
        "import java.util.Locale;",
        "",
        "class PetTypeFormatter {",
        "    public String print(Locale locale) {",
        "        return locale.toLanguageTag();",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Remove package import blank line" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "mutation commit failed" }
    $commitHash = (& git rev-parse HEAD).Trim()

    $pocket = [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
        generatedFromHead = $baseHead
        candidates = @(
            [ordered]@{
                candidateId = "canary-method-spacing"
                candidateClass = "method_spacing_normalization"
                file = $javaPath
                member = "line-2"
            }
        )
    }
    $pocketPath = "candidate-pocket.json"
    $pocket | ConvertTo-Json -Depth 6 | Set-Content $pocketPath

    $provenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $baseHead `
        -CommitHash $commitHash `
        -CandidatePocketPath $pocketPath

    Assert-True -Condition ($provenance.independentlyObservedDiffClass -eq "import_spacing_normalization") -Name "package import spacing independently classified"
    Assert-False -Condition ([bool]$provenance.candidateClassProvenanceMatched) -Name "method spacing receipt cannot claim import spacing diff"

    $badReceipt = [pscustomobject]@{
        candidateClassProvenance = $provenance
    }
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $badReceipt -ReceiptPath "bad-receipt.json"
        throw "Expected provenance assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "candidateClassProvenanceMatched=false") {
            throw
        }
        Write-Host "passed=negative provenance receipt is rejected"
    }

    $legacyReceipt = [pscustomobject]@{
        candidateClass = "method_spacing_normalization"
    }
    Assert-False -Condition (Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $legacyReceipt) -Name "legacy receipt without provenance is not positive learning evidence"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $legacyReceipt -ReceiptPath "legacy-receipt.json" -RequirePresent
        throw "Expected missing provenance assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "candidateClassProvenance missing") {
            throw
        }
        Write-Host "passed=current PR receipt without provenance is rejected"
    }

    Write-CanaryFile -Path $javaPath -Lines @(
        "package org.example;",
        "",
        "import java.util.Locale;",
        "",
        "class PetTypeFormatter {",
        "    public String print(Locale locale) {",
        "        return locale.toLanguageTag();",
        "    }",
        "",
        "    public String parse(String text) {",
        "        return text;",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Add adjacent method canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "method base commit failed" }
    $methodBase = (& git rev-parse HEAD).Trim()

    $methodPocket = [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
        generatedFromHead = $methodBase
        candidates = @(
            [ordered]@{
                candidateId = "canary-method-spacing-valid"
                candidateClass = "method_spacing_normalization"
                file = $javaPath
                member = "line-9"
                spacingAction = "collapse_extra_blank_line"
            }
        )
    }
    $methodPocketPath = "method-pocket.json"
    $methodPocket | ConvertTo-Json -Depth 6 | Set-Content $methodPocketPath
    $methodDiscoveryEvidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot "discovery-evidence" -CandidateId "canary-method-spacing-valid" -BaseHead $methodBase
    $methodDiscoveryEvidence = New-ThresholdCandidateDiscoveryEvidence -BaseHead $methodBase -CandidateId "canary-method-spacing-valid" -CandidatePocketPath $methodPocketPath
    Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $methodDiscoveryEvidence -Path $methodDiscoveryEvidencePath
    & git add -- $methodDiscoveryEvidencePath $methodPocketPath
    & git commit -m "Record method spacing discovery evidence" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "method discovery evidence commit failed" }
    $methodSourceBase = (& git rev-parse HEAD).Trim()

    Write-CanaryFile -Path $javaPath -Lines @(
        "package org.example;",
        "",
        "import java.util.Locale;",
        "",
        "class PetTypeFormatter {",
        "    public String print(Locale locale) {",
        "        return locale.toLanguageTag();",
        "    }",
        "    public String parse(String text) {",
        "        return text;",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Collapse method spacing" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "method spacing commit failed" }
    $methodCommit = (& git rev-parse HEAD).Trim()

    $validProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -PrBaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidatePocketPath $methodPocketPath `
        -DiscoveryEvidenceRoot "discovery-evidence" `
        -DiscoveryEvidencePath $methodDiscoveryEvidencePath

    Assert-True -Condition ($validProvenance.independentlyObservedDiffClass -eq "method_spacing_normalization") -Name "method spacing independently classified"
    Assert-True -Condition ([bool]$validProvenance.candidatePathMatched) -Name "method spacing observed diff path matches candidate snapshot"
    Assert-True -Condition ([bool]$validProvenance.candidateMemberMatched) -Name "method spacing observed hunk matches candidate member"
    Assert-True -Condition ([bool]$validProvenance.immutableDiscoveryEvidencePresent) -Name "immutable discovery evidence is present"
    Assert-True -Condition ([bool]$validProvenance.prBaseHeadPresent) -Name "PR base head is present"
    Assert-True -Condition ([bool]$validProvenance.prBaseHeadMatched) -Name "PR base head is independently bound"
    Assert-False -Condition ([bool]$validProvenance.discoveryEvidenceChangedInsideProductPr) -Name "pre-existing discovery evidence is unchanged inside product PR"
    Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$validProvenance.discoveryEvidence)) -Name "receipt provenance does not embed discovery evidence"
    Assert-False -Condition ([bool]$validProvenance.fallbackToMutableCurrentPocket) -Name "mutable current pocket fallback is disabled"
    Assert-False -Condition ([bool]$validProvenance.fallbackToReceiptEmbeddedSnapshot) -Name "receipt embedded snapshot fallback is disabled"
    Assert-False -Condition ([bool]$validProvenance.fallbackToReceiptSuppliedBooleans) -Name "receipt supplied boolean fallback is disabled"
    Assert-True -Condition ([bool]$validProvenance.candidateClassProvenanceMatched) -Name "matching method spacing provenance is admitted"
    $validReceipt = [pscustomobject]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        baseHead = $methodSourceBase
        commitHash = $methodCommit
        candidateClassProvenance = $validProvenance
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $validReceipt -ReceiptPath "valid-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
    Write-Host "passed=positive provenance receipt is admitted"
    Write-Host "passed=evidence_preexists_on_pr_base"

    $leasePath = "threshold/leases/current.yaml"
    $leaseDir = Split-Path $leasePath -Parent
    if (-not (Test-Path $leaseDir)) { New-Item -ItemType Directory -Path $leaseDir | Out-Null }
    @(
        "leaseName: canary-lease",
        "branch: canary/product-branch",
        "startHead: $methodSourceBase"
    ) | Set-Content $leasePath
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $missingPrBaseOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $thresholdScriptRoot "record-receipt.ps1") `
        -LeasePath $leasePath `
        -CandidateId "canary-method-spacing-valid" `
        -CandidateClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidatePocketPath $methodPocketPath `
        -DiscoveryEvidencePath $methodDiscoveryEvidencePath `
        -DryRun 2>&1)
    $missingPrBaseExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($missingPrBaseExitCode -eq 0) {
        throw "Expected record-receipt without PR base to fail."
    }
    if (($missingPrBaseOutput -join "`n") -notmatch "candidateClassProvenanceMatched=false") {
        throw "Unexpected record-receipt without PR base failure: $($missingPrBaseOutput -join ' ')"
    }
    Write-Host "passed=normal receipt generation without pr base fails closed"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $thresholdScriptRoot "record-receipt.ps1") `
        -LeasePath $leasePath `
        -CandidateId "canary-method-spacing-valid" `
        -CandidateClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -PrBaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidatePocketPath $methodPocketPath `
        -DiscoveryEvidencePath $methodDiscoveryEvidencePath `
        -DryRun | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "record-receipt with PR base failed." }
    Write-Host "passed=normal receipt generation with pr base succeeds"

    $completeSliceText = Get-Content (Join-Path $thresholdScriptRoot "complete-slice.ps1") -Raw
    Assert-False -Condition ($completeSliceText -match "Write-ThresholdCandidateDiscoveryEvidence") -Name "complete-slice does not materialize discovery evidence"
    Assert-False -Condition ($completeSliceText -match "Record Threshold discovery evidence") -Name "complete-slice does not commit discovery evidence"
    Assert-True -Condition ($completeSliceText -match "Pre-product discovery evidence is required before complete-slice") -Name "complete-slice requires pre-product discovery evidence"
    Assert-True -Condition ($completeSliceText -match 'Test-ThresholdCommitIsAncestor -Ancestor \$observedPrBaseHead -Descendant \$baseHead') -Name "complete-slice allows later slices to descend from PR base"
    Assert-True -Condition ($completeSliceText -match 'preProductDiscoverySourceHead') -Name "complete-slice prefers stable pre-product discovery source head"
    Assert-True -Condition ($completeSliceText -match 'generatedFromHead') -Name "complete-slice derives discovery source head from candidate pocket"
    Assert-True -Condition ($completeSliceText -match 'CandidateId \$CandidateId -BaseHead \$discoverySourceHead') -Name "complete-slice locates discovery evidence at discovery source head"
    Assert-True -Condition ($completeSliceText -match "Resolve-GitRefWithOriginFallback") -Name "complete-slice uses canonical PR base ref resolver"
    Assert-True -Condition ($completeSliceText -match '\$remoteQualified = \$remotes -contains \$Matches\[1\]') -Name "complete-slice checks slash ref prefixes against configured git remotes"
    Assert-True -Condition ($completeSliceText -match '\$candidateRefs\.Add\("origin/\$trimmedRef"\)') -Name "complete-slice preserves origin fallback for slash-containing branch names"
    Assert-True -Condition ($completeSliceText -match '\$candidateRefs\.Add\(\$trimmedRef\)') -Name "complete-slice resolves remote-qualified PR base refs verbatim"
    Assert-False -Condition ($completeSliceText -match 'origin/\$\{effectiveBaseRef\}') -Name "complete-slice does not force origin onto remote-qualified PR base refs"

    $prepareDiscoveryEvidenceText = Get-Content (Join-Path $thresholdScriptRoot "prepare-discovery-evidence.ps1") -Raw
    Assert-True -Condition ($prepareDiscoveryEvidenceText -match "Write-ThresholdCandidateDiscoveryEvidence") -Name "pre-product producer materializes discovery evidence"
    Assert-True -Condition ($prepareDiscoveryEvidenceText -match "generatedFromHead") -Name "pre-product producer binds discovery source head"
    Assert-True -Condition ($prepareDiscoveryEvidenceText -match "Test-ThresholdCommitIsAncestor") -Name "pre-product producer verifies source ancestry"

    $startNextWaveText = Get-Content (Join-Path $thresholdScriptRoot "start-next-wave.ps1") -Raw
    Assert-True -Condition ($startNextWaveText -match "Invoke-PreProductDiscoveryPreparation") -Name "start-next-wave invokes pre-product discovery preparation"
    Assert-True -Condition ($startNextWaveText -match "Set-PreProductDiscoverySourceHead") -Name "start-next-wave preserves pre-product source head across pocket refreshes"
    Assert-True -Condition ($startNextWaveText -match "preProductDiscoveryEvidencePolicy") -Name "start-next-wave documents pocket evidence-source policy"
    Assert-True -Condition ($startNextWaveText -match "Prepare Threshold wave .* discovery evidence") -Name "start-next-wave commits discovery evidence before product branch"
    Assert-True -Condition ($startNextWaveText -match "PullRequestBaseBranch") -Name "start-next-wave creates PR against evidence-bearing base branch"
    Assert-True -Condition ($startNextWaveText -match '"-BranchName",\s*\$branch') -Name "start-next-wave binds lease to product branch before slice execution"
    Assert-True -Condition ($startNextWaveText -match '"-BaseRef",\s*"\$BaseRemote/\$evidenceBranch"') -Name "start-next-wave binds lease baseRef to evidence-bearing PR base"
    Assert-True -Condition ($startNextWaveText -match "midWaveScopeExpansionBlocked=true") -Name "start-next-wave blocks mid-wave scope expansion after product branch start"
    Assert-False -Condition ($startNextWaveText -match 'Try-ExpandScopeForCandidateShortage -Reason "mid_wave_candidate_shortage"') -Name "start-next-wave does not create discovery evidence inside the product PR for mid-wave scope expansion"
    Assert-True -Condition ($startNextWaveText -match "Assert-PullRequestBaseHasThresholdGovernanceTrigger") -Name "start-next-wave fails closed when PR base lacks Threshold governance trigger"
    Assert-True -Condition ($startNextWaveText -match "unsupported_branch_prefix_for_threshold_governance") -Name "start-next-wave rejects unsupported branch prefixes before publication"
    Assert-True -Condition ($startNextWaveText -match '\$SupportedGovernanceBranchPrefix = "threshold-governed-refactor-demo-"') -Name "start-next-wave binds supported branch prefix to governance workflow trigger"
    Assert-True -Condition ($startNextWaveText -match "threshold-governed-refactor-demo-.*-discovery-base") -Name "start-next-wave recognizes generated evidence bases covered by workflow trigger"
    Assert-True -Condition ($startNextWaveText -match '\"-PrBaseHead\"') -Name "start-next-wave passes evidence-bearing PR base to run-next-slice"
    Assert-True -Condition ($startNextWaveText -match '\"-CandidatePocketPath\",\s*\$PocketPath') -Name "start-next-wave passes prepared candidate pocket to run-next-batch"
    Assert-True -Condition ($startNextWaveText -match '\"-RequirePreProductDiscoveryEvidence\"') -Name "start-next-wave requires pre-product discovery evidence for batch execution"
    Assert-True -Condition ($startNextWaveText -match "ExpectedBaseBranch") -Name "start-next-wave reconciles the actual PR base branch after merge"
    Assert-True -Condition ($startNextWaveText -match "Invoke-GovernedEvidenceBasePromotion") -Name "start-next-wave promotes evidence base only through governed PR"
    Assert-True -Condition ($startNextWaveText -match "New-GovernedEvidenceBasePromotionBody") -Name "start-next-wave materializes governed evidence promotion PR body"
    Assert-True -Condition ($startNextWaveText -match "governedEvidenceBasePromotion=merged") -Name "start-next-wave reconciles governed evidence promotion merge"
    Assert-True -Condition ($startNextWaveText -match '"pr",\s*"create",\s*"--repo",\s*\$OwnedRepo,\s*"--base",\s*\$BaseBranch') -Name "start-next-wave creates promotion PR against configured base"
    Assert-True -Condition ($startNextWaveText -match 'Invoke-PullRequestVerification -PullRequest \$promotionPr') -Name "start-next-wave verifies promotion PR before merge"
    Assert-False -Condition ($startNextWaveText -match '\$\(\$mergeCommit\):refs/heads/\$BaseBranch') -Name "start-next-wave does not push evidence-base merge commits directly to configured base"
    Assert-True -Condition ($startNextWaveText -match "candidatePocketRefreshBlocked=true") -Name "start-next-wave blocks product-branch candidate pocket refresh"
    Assert-True -Condition ($startNextWaveText -match "pre-product evidence-bearing candidate pocket") -Name "start-next-wave documents stable prepared candidate pocket policy"

    $startLeaseText = Get-Content (Join-Path $thresholdScriptRoot "start-lease.ps1") -Raw
    Assert-True -Condition ($startLeaseText -match '\[string\] \$BranchName = ""') -Name "start-lease supports explicit product branch binding"
    Assert-True -Condition ($startLeaseText -match '\[string\] \$BaseRef = "origin/main"') -Name "start-lease supports explicit PR base binding"
    Assert-True -Condition ($startLeaseText -match '\$branch = if \(\[string\]::IsNullOrWhiteSpace\(\$BranchName\)\)') -Name "start-lease defaults to observed branch only when no branch binding is supplied"
    Assert-True -Condition ($startLeaseText -match 'baseRef: \$BaseRef') -Name "start-lease records supplied PR base ref"
    Assert-True -Condition ($startLeaseText -match 'threshold/discovery-evidence/\*\.json') -Name "start-lease allowlist admits discovery evidence artifacts"

    $thresholdGovernanceWorkflowText = Get-Content (Join-Path $repoRoot ".github/workflows/threshold-governance.yml") -Raw
    Assert-True -Condition ($thresholdGovernanceWorkflowText -match "threshold-governed-refactor-demo-\*-discovery-base") -Name "Threshold governance workflow runs for evidence-bearing PR base branches"

    $runNextSliceText = Get-Content (Join-Path $thresholdScriptRoot "run-next-slice.ps1") -Raw
    Assert-True -Condition ($runNextSliceText -match 'preProductDiscoverySourceHead') -Name "run-next-slice uses stable pre-product discovery source head"
    Assert-True -Condition ($runNextSliceText -match 'Test-ThresholdCommitIsAncestor -Ancestor \$evidenceSourceHead -Descendant \$head') -Name "run-next-slice keeps execution pocket aligned with prepared evidence"
    Assert-True -Condition ($runNextSliceText -match '\"-PrBaseHead\", \$PrBaseHead') -Name "run-next-slice forwards observed PR base to complete-slice"
    Assert-True -Condition ($runNextSliceText -match 'ProcessedCandidateIds') -Name "run-next-slice filters already processed immutable candidate IDs"
    Assert-True -Condition ($runNextSliceText -match 'candidateSkippedReason=already_processed') -Name "run-next-slice reports already processed candidate suppression"
    Assert-True -Condition ($runNextSliceText -match 'line_rebinding_required_after_prior_line_mutation') -Name "run-next-slice fail-closes remaining line candidates after prior line mutation"

    $kgMaterializationText = Get-Content (Join-Path $thresholdScriptRoot "materialize-knowledge-graphs.ps1") -Raw
    Assert-True -Condition ($kgMaterializationText -match '\$\{ObservedPrBaseHead\}\.\.\.HEAD') -Name "KG materialization honors supplied PR base without BaseRef"
    Assert-True -Condition ($kgMaterializationText -match 'return \$ObservedPrBaseHead') -Name "KG materialization distinguishes current PR receipts from historical receipts"

    $prGovernanceText = Get-Content (Join-Path $thresholdScriptRoot "test-pr-governance.ps1") -Raw
    Assert-True -Condition ($prGovernanceText -match "ConvertTo-PrVisibleBaseRef") -Name "PR governance normalizes lease base refs to PR-visible branch refs"
    Assert-True -Condition ($prGovernanceText -match "ConvertTo-RemoteIndependentLeaseBaseRef") -Name "PR governance normalizes promotion lease bases independently of CI remotes"
    Assert-True -Condition ($prGovernanceText -match "ConvertTo-OriginResolvedEvidenceRef") -Name "PR governance resolves launcher-local evidence remotes through origin in CI"
    Assert-True -Condition ($prGovernanceText -match "Resolve-BaseRefForGit") -Name "PR governance resolves configured base refs through a canonical helper"
    Assert-True -Condition ($prGovernanceText -match 'ObservedPrBaseRef') -Name "PR governance strips configured remote aliases without relying on CI remotes"
    Assert-True -Condition ($prGovernanceText -match '\$resolvedBaseRefForGit\.\.HEAD') -Name "PR governance uses resolved base refs for commit ranges"
    Assert-True -Condition ($prGovernanceText -match '\$prVisibleBaseRef -ne \$expectedPrVisibleBaseRef') -Name "PR governance compares PR-visible base refs after remote-prefix normalization"
    Assert-True -Condition ($prGovernanceText -match 'governedEvidenceBasePromotionPr') -Name "PR governance recognizes governed evidence-base promotion PRs"
    Assert-True -Condition ($prGovernanceText -match 'evidenceReceiptPrBaseHead') -Name "PR governance validates receipts against the evidence-bearing PR base during promotion"
    Assert-True -Condition ($prGovernanceText -match 'Governed evidence-base promotion does not descend from configured PR base') -Name "PR governance verifies promotion evidence base descends from configured base"
    Assert-True -Condition ($prGovernanceText -match 'Assert-PromotionSquashCommitCoveredByReceipts') -Name "PR governance reconciles promotion squash commits to source receipts"
    Assert-True -Condition ($prGovernanceText -match 'promotionReceiptEntries') -Name "PR governance carries promotion receipt entries into metadata validation"
    Assert-True -Condition ($prGovernanceText -match 'expectedMetadataSourceCommits') -Name "PR governance validates promotion metadata against pre-squash source commits"
    Assert-True -Condition ($prGovernanceText -match 'Get-CommitPathBlobSha256 -Commit \$Commit -Path \$path') -Name "PR governance validates promoted product content hashes"
    Assert-True -Condition ($prGovernanceText -match '\$Receipt\.candidates') -Name "PR governance reads batch candidate hashes for promotion reconciliation"
    Assert-True -Condition ($prGovernanceText -match '\$currentWaveReceiptEntries') -Name "PR governance scopes promotion receipts to the current wave"
    Assert-True -Condition ($prGovernanceText -match 'return @\(\$currentWaveReceiptEntries\.ToArray\(\)\)') -Name "PR governance retains every current-wave promotion receipt"
    Assert-True -Condition ($prGovernanceText -match 'Batch candidate same-path hash chain mismatch') -Name "PR governance validates same-path batch candidate hash chains"
    Assert-True -Condition ($prGovernanceText -match 'Batch candidate path first beforeSha256 mismatch') -Name "PR governance binds same-path batch chain to parent blob"
    Assert-True -Condition ($prGovernanceText -match 'Batch candidate path final afterSha256 mismatch') -Name "PR governance binds same-path batch chain to final blob"
    Assert-True -Condition ($prGovernanceText -match 'Test-ThresholdRepeatedCommentWrapDiff') -Name "PR governance classifies multi-candidate same-file comment wraps"
    Assert-True -Condition ($prGovernanceText -match 'Get-ObservedBatchCandidateDiffClassForPath') -Name "PR governance uses batch-aware candidate diff classification"
    Assert-True -Condition ($prGovernanceText -match 'Assert-RepeatedCommentWrapDiffMatchesCandidates') -Name "PR governance binds repeated wraps to candidate line members"
    Assert-True -Condition ($prGovernanceText -match 'Batch repeated comment wrap candidate line mismatch') -Name "PR governance rejects repeated wraps at unclaimed candidate lines"
    Assert-True -Condition ($prGovernanceText -match 'Batch repeated comment wrap per-candidate text mismatch') -Name "PR governance rejects repeated wraps that only preserve aggregate text"
    Assert-True -Condition ($prGovernanceText -match 'Promotion squash commit content mismatch') -Name "PR governance rejects tampered promotion content on receipt-covered paths"
    Assert-True -Condition ($prGovernanceText -match 'Promotion squash commit has no current-wave product source receipts') -Name "PR governance rejects promotion without current-wave source receipts"
    Assert-True -Condition ($prGovernanceText -match 'promotionSquashReceiptReconciliation=passed') -Name "PR governance reports promotion squash receipt reconciliation"
    Assert-True -Condition ($prGovernanceText -match 'promotionSquashContentReconciliation=passed') -Name "PR governance reports promotion squash content reconciliation"
    Assert-False -Condition ($prGovernanceText -match 'Ancestor \$receiptParentHead -Descendant \$effectiveReceiptPrBaseHead') -Name "PR governance does not require source parent ancestry toward promotion evidence head"
    Assert-True -Condition ($prGovernanceText -match 'Ancestor \$receiptPrBaseHead -Descendant \$receiptParentHead') -Name "PR governance validates receipt prBaseHead against source base"
    Assert-True -Condition ($prGovernanceText -match 'Promotion receipt immutable prBaseHead is not ancestor of source base') -Name "PR governance rejects receipt source base outside immutable PR base"
    Assert-True -Condition ($prGovernanceText -match 'function Resolve-ReceiptPrBaseHead') -Name "PR governance resolves canonical receipt PR base through one helper"
    Assert-True -Condition ($prGovernanceText -match 'Get-ThresholdJsonProperty \$provenance "prBaseHead"') -Name "PR governance reads single receipt PR base from candidateClassProvenance"
    Assert-True -Condition ($prGovernanceText -match 'Get-ThresholdJsonProperty \$binding "prBaseHead"') -Name "PR governance reads batch receipt PR base from candidate discovery evidence"
    Assert-True -Condition ($prGovernanceText -match 'multiple conflicting canonical prBaseHead bindings') -Name "PR governance rejects batch receipts with differing PR bases"
    Assert-True -Condition ($prGovernanceText -match 'only non-canonical top-level prBaseHead') -Name "PR governance rejects top-level-only PR base claims"
    Assert-True -Condition ($prGovernanceText -match 'canonical prBaseHead is malformed') -Name "PR governance rejects malformed canonical PR base heads"
    Assert-True -Condition ($prGovernanceText -match '\$receiptPrBaseHead = Resolve-ReceiptPrBaseHead') -Name "PR governance validates promotion against canonical nested receipt PR base"
    Assert-False -Condition ($prGovernanceText -match 'Get-ThresholdJsonProperty \$receipt "prBaseHead" ""\)\s*[\r\n]+\s*if \(\[string\]::IsNullOrWhiteSpace\(\$receiptClaimedPrBaseHead\)') -Name "PR governance does not require top-level prBaseHead during promotion"
    Assert-True -Condition ($prGovernanceText -match 'Ancestor \$receiptPrBaseHead -Descendant \$effectiveReceiptPrBaseHead') -Name "PR governance separately checks receipt prBaseHead reaches promotion evidence head"
    Assert-True -Condition ($prGovernanceText -match 'receiptPrBaseHead') -Name "PR governance preserves immutable receipt PR base during promotion validation"
    Assert-True -Condition ($prGovernanceText -match 'sourceBaseHead') -Name "PR governance checks source parent base separately from receipt PR base"
    Assert-True -Condition ($prGovernanceText -match 'Promotion squash commit is not covered by source receipt changedFiles') -Name "PR governance rejects uncovered promotion squash product paths"
    Assert-True -Condition ($prGovernanceText -match '\$actualProductPaths') -Name "PR governance inventories all batch source product paths"
    Assert-True -Condition ($prGovernanceText -match 'product changes without candidate coverage') -Name "PR governance rejects batch source paths without candidate coverage"
    Assert-True -Condition ($prGovernanceText -match '\$isPromotionReconciledCommit') -Name "PR governance separates promotion reconciliation validation mode"
    Assert-True -Condition ($prGovernanceText -match 'foreach \(\$entry in \$entriesToValidate\)') -Name "PR governance validates every reconciled promotion receipt"
    Assert-True -Condition ($prGovernanceText -match '\$changedFilesCommit = if \(\$isPromotionReconciledCommit\)') -Name "PR governance validates promotion changed files against source receipts"
    Assert-True -Condition ((Get-Content (Join-Path $thresholdScriptRoot "lib/lease-policy.ps1") -Raw) -match 'threshold/discovery-evidence/\*') -Name "lease policy classifies discovery evidence as governance evidence"

    $runNextBatchText = Get-Content (Join-Path $thresholdScriptRoot "run-next-batch.ps1") -Raw
    Assert-True -Condition ($runNextBatchText -match '\[string\] \$CandidatePocketPath = ""') -Name "run-next-batch accepts a prepared candidate pocket"
    Assert-True -Condition ($runNextBatchText -match '\[string\] \$PrBaseHead = ""') -Name "run-next-batch accepts an observed PR base head"
    Assert-True -Condition ($runNextBatchText -match "Assert-BatchCandidateHasPreProductDiscoveryEvidence") -Name "run-next-batch requires pre-product evidence for every batched candidate"
    Assert-True -Condition ($runNextBatchText -match "Get-ThresholdCandidateDiscoveryEvidenceFromRevision") -Name "run-next-batch reads batch discovery evidence from PR base"
    Assert-True -Condition ($runNextBatchText -match "candidateDiscoveryEvidence") -Name "run-next-batch records per-candidate discovery evidence binding"
    $scopeDrainText = Get-Content (Join-Path $thresholdScriptRoot "run-until-scope-exhausted.ps1") -Raw
    Assert-True -Condition ($scopeDrainText -match "Invoke-PreProductDiscoveryPreparation") -Name "scope-drain prepares pre-product discovery evidence before slices"
    Assert-True -Condition ($scopeDrainText -match 'git check-ignore') -Name "scope-drain does not stage ignored runtime paths"
    Assert-True -Condition ($scopeDrainText -match '\$preparationCommitPaths = if \(\$EvidenceMode -eq "Compact"\) \{ @\(\$evidencePaths\) \}') -Name "scope-drain compact preparation commits only persistent discovery evidence"
    Assert-True -Condition ($scopeDrainText -match "AllowEmpty") -Name "scope-drain can accept empty discovery evidence for true scope exhaustion"
    Assert-True -Condition ($scopeDrainText -match 'allowEmptyEvidence = \$autoPatchableCandidateCount -lt \$MinAutoPatchableCandidates') -Name "scope-drain binds empty evidence allowance to eligible candidate count"
    Assert-True -Condition ($scopeDrainText -match "segmentPreparedPrBaseHead=") -Name "scope-drain materializes prepared PR base head once per segment"
    Assert-True -Condition ($scopeDrainText -match '\$args \+= @\("-PrBaseHead", \$SegmentPreparedPrBaseHead\)') -Name "scope-drain passes frozen segment PR base to run-next-slice"
    Assert-False -Condition ($scopeDrainText -match '\$prBaseHead = \(& git rev-parse HEAD\)\.Trim\(\)') -Name "scope-drain does not recompute PR base from product HEAD between segment slices"
    Assert-True -Condition ($scopeDrainText -match "scope-drain segment preserves prepared pocket across product slices") -Name "scope-drain keeps prepared pocket stable across segment slices"
    Assert-True -Condition ($scopeDrainText -match "scopeDrainSegmentRequiresFreshDiscovery=true") -Name "scope-drain requires fresh discovery after a processed segment"
    Assert-True -Condition ($scopeDrainText -match "processed segment cannot independently prove global scope exhaustion") -Name "scope-drain does not use old prepared pocket as global exhaustion proof"
    Assert-True -Condition ($scopeDrainText -match "runStartHead=") -Name "scope-drain preserves immutable run start head"
    Assert-True -Condition ($scopeDrainText -match "cumulativeProcessedCandidateCount") -Name "scope-drain preserves cumulative processed candidate count across segments"
    Assert-True -Condition ($scopeDrainText -match "terminalRunProcessedCandidateCount") -Name "scope-drain aggregate receipt reports run-level processed count"
    Assert-True -Condition ($scopeDrainText -match "verificationSegmentProcessedCandidateCount") -Name "scope-drain aggregate receipt separates verification segment count"
    Assert-False -Condition ($scopeDrainText -match "Record Threshold scope drain segment .* updated candidate pocket") -Name "scope-drain does not refresh discovery identity between segment slices"
    Assert-True -Condition ($startNextWaveText -match 'return \$promotionMergedPullRequest') -Name "start-next-wave reports configured-base promotion merge result"
    Assert-True -Condition ($runNextBatchText -match 'ProcessedCandidateIds') -Name "run-next-batch excludes already processed candidate IDs"
    Assert-True -Condition ($runNextBatchText -match 'line_rebinding_required_after_prior_line_mutation') -Name "run-next-batch fail-closes remaining line candidates after prior line mutation"
    Assert-True -Condition ($runNextBatchText -match 'processedCandidateIds') -Name "run-next-batch records processed candidate IDs in lease state"
    Assert-True -Condition ((Get-Content (Join-Path $thresholdScriptRoot "record-receipt.ps1") -Raw) -match 'processedCandidateIds') -Name "record-receipt records processed candidate IDs"
    Assert-True -Condition ((Get-Content (Join-Path $thresholdScriptRoot "start-lease.ps1") -Raw) -match 'processedCandidateIds = @\(\)') -Name "start-lease initializes processed candidate IDs"
    Assert-True -Condition ($prGovernanceText -match "Assert-BatchCandidateDiscoveryEvidenceMatchesPrBase") -Name "PR governance validates batch candidate discovery evidence"
    Assert-True -Condition ($prGovernanceText -match "Batch candidate discovery evidence must pre-exist in PR baseHead") -Name "PR governance rejects forged batch evidence missing from PR base"
    Assert-True -Condition ($prGovernanceText -match "Batch candidate discovery evidence digest mismatch") -Name "PR governance rejects forged batch evidence digests"
    Assert-True -Condition ($prGovernanceText -match "Batch candidate file was not changed by source commit") -Name "PR governance reconciles batch candidate path to source diff"
    Assert-True -Condition ($prGovernanceText -match "Batch candidate discovery evidence candidateMember mismatch") -Name "PR governance reconciles batch candidate member to base evidence"

    $missingPrBaseProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidatePocketPath $methodPocketPath `
        -DiscoveryEvidenceRoot "discovery-evidence" `
        -DiscoveryEvidencePath $methodDiscoveryEvidencePath
    Assert-False -Condition ([bool]$missingPrBaseProvenance.prBaseHeadPresent) -Name "missing PR base head is visible"
    Assert-False -Condition ([bool]$missingPrBaseProvenance.candidateClassProvenanceMatched) -Name "missing PR base head rejects provenance"
    Write-Host "passed=pr_base_missing"

    $forgedPrBaseReceipt = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $forgedPrBaseReceipt.candidateClassProvenance.prBaseHead = $methodBase
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $forgedPrBaseReceipt -ReceiptPath "forged-pr-base-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected forged PR base assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "prBaseHead claim mismatch|recompute mismatch") {
            throw
        }
        Write-Host "passed=receipt_claims_forged_pr_base"
    }

    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $validReceipt -ReceiptPath "swapped-pr-base-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodCommit
        throw "Expected swapped PR/source base assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "prBaseHead is not ancestor of source baseHead|receipt prBaseHead claim mismatch") {
            throw
        }
        Write-Host "passed=source_base_and_pr_base_swapped"
    }

    $wrongSpacingActionCandidate = [ordered]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        file = $javaPath
        member = "line-9"
        spacingAction = "insert_blank_line"
    }
    $wrongSpacingActionProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidateSnapshot $wrongSpacingActionCandidate
    Assert-False -Condition ([bool]$wrongSpacingActionProvenance.candidateExecutionParametersMatched) -Name "method spacing mismatched execution parameter is rejected"
    Assert-False -Condition ([bool]$wrongSpacingActionProvenance.candidateClassProvenanceMatched) -Name "method spacing wrong execution parameter blocks provenance"

    $methodSnapshotA = New-ThresholdCandidateSnapshot -Candidate $methodPocket.candidates[0]
    $methodSnapshotB = New-ThresholdCandidateSnapshot -Candidate $wrongSpacingActionCandidate
    Assert-False -Condition ((Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $methodSnapshotA) -eq (Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $methodSnapshotB)) -Name "snapshot digest changes when spacingAction changes"
    Assert-True -Condition (Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $validReceipt) -Name "positive learning requires immutable discovery evidence"

    $receiptClassTamper = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $receiptClassTamper.candidateClass = "import_spacing_normalization"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $receiptClassTamper -ReceiptPath "receipt-class-tamper.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected top-level candidate class mismatch assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "receiptCandidateClass") {
            throw
        }
        Write-Host "passed=top-level receipt candidate class is bound to provenance recompute"
    }

    $stalePocket = [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
        generatedFromHead = $methodBase
        candidates = @()
    }
    $stalePocketPath = "stale-pocket.json"
    $stalePocket | ConvertTo-Json -Depth 6 | Set-Content $stalePocketPath
    $missingEvidenceReceipt = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $missingEvidenceReceipt.candidateClassProvenance.discoveryEvidencePath = "missing-discovery-evidence.json"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $missingEvidenceReceipt -ReceiptPath "missing-discovery-evidence.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected missing immutable discovery evidence assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "discovery evidence artifact missing") {
            throw
        }
        Write-Host "passed=missing immutable discovery evidence rejects embedded snapshot fallback"
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $validReceipt -ReceiptPath "immutable-discovery-evidence.json" -CandidatePocketPath $stalePocketPath -PrBaseHead $methodSourceBase
    Write-Host "passed=valid immutable discovery evidence admits even when mutable pocket no longer contains candidate"

    $embeddedDiscoveryReceipt = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $embeddedDiscoveryReceipt.candidateClassProvenance.discoveryEvidence = Get-Content -LiteralPath $validProvenance.discoveryEvidencePath -Raw | ConvertFrom-Json
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $embeddedDiscoveryReceipt -ReceiptPath "embedded-discovery-evidence.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected embedded discovery evidence assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "external immutable artifact") {
            throw
        }
        Write-Host "passed=receipt-embedded discovery evidence cannot self-anchor provenance"
    }

    $snapshotDigestTamper = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $snapshotDigestTamper.candidateClassProvenance.executionCandidateSnapshot.member = "line-99"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $snapshotDigestTamper -ReceiptPath "snapshot-digest-tamper.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected receipt-bound snapshot digest assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "execution snapshot digest mismatch") {
            throw
        }
        Write-Host "passed=receipt-bound execution snapshot digest is immutable"
    }

    $discoveryDigestTamper = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $discoveryDigestTamper.candidateClassProvenance.discoveryEvidenceDigest = "tampered"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $discoveryDigestTamper -ReceiptPath "discovery-digest-tamper.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected discovery evidence digest assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "discovery evidence digest mismatch") {
            throw
        }
        Write-Host "passed=discovery evidence digest tampering is rejected"
    }

    $selfAnchoredReceipt = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $selfAnchoredReceipt.candidateId = "invented-method-spacing-candidate"
    $selfAnchoredReceipt.candidateClassProvenance.discoveryCandidateId = "invented-method-spacing-candidate"
    $selfAnchoredReceipt.candidateClassProvenance.executionCandidateSnapshot.candidateId = "invented-method-spacing-candidate"
    $selfAnchoredReceipt.candidateClassProvenance.executionCandidateDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $selfAnchoredReceipt.candidateClassProvenance.executionCandidateSnapshot
    $selfAnchoredReceipt.candidateClassProvenance.discoveryEvidencePath = "missing-invented-discovery-evidence.json"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $selfAnchoredReceipt -ReceiptPath "self-anchored-receipt.json" -CandidatePocketPath $stalePocketPath -PrBaseHead $methodSourceBase
        throw "Expected self-anchored receipt assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "discovery evidence artifact missing") {
            throw
        }
        Write-Host "passed=receipt-invented candidate snapshot cannot establish discovery trust"
    }

    $staleReceipt = $validReceipt | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $staleReceipt.candidateClassProvenance.provenanceDigest = "stale"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $staleReceipt -ReceiptPath "stale-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected stale provenance digest assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "recompute mismatch") {
            throw
        }
        Write-Host "passed=stale provenance digest is recomputed and rejected"
    }

    $sourceCommitReceipt = [pscustomobject]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        baseHead = $methodSourceBase
        sourceCommit = $methodCommit
        candidateClassProvenance = $validProvenance
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $sourceCommitReceipt -ReceiptPath "source-commit-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
    Write-Host "passed=sourceCommit provenance is recomputed and admitted"

    $otherJavaPath = "src/main/java/org/example/OtherFormatter.java"
    Write-CanaryFile -Path $otherJavaPath -Lines @(
        "package org.example;",
        "class OtherFormatter {",
        "    public String print(String text) {",
        "        return text;",
        "    }",
        "",
        "    public String parse(String text) {",
        "        return text;",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Add second formatter canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "second formatter base commit failed" }
    $otherBase = (& git rev-parse HEAD).Trim()
    Write-CanaryFile -Path $otherJavaPath -Lines @(
        "package org.example;",
        "class OtherFormatter {",
        "    public String print(String text) {",
        "        return text;",
        "    }",
        "    public String parse(String text) {",
        "        return text;",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Collapse second formatter spacing" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "second formatter mutation commit failed" }
    $otherCommit = (& git rev-parse HEAD).Trim()
    $wrongPathProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $otherBase `
        -CommitHash $otherCommit `
        -CandidateSnapshot $methodPocket.candidates[0]
    Assert-True -Condition ($wrongPathProvenance.independentlyObservedDiffClass -eq "method_spacing_normalization") -Name "foreign-path method spacing is independently classified"
    Assert-False -Condition ([bool]$wrongPathProvenance.candidatePathMatched) -Name "observed diff path must match candidate snapshot file"
    Assert-False -Condition ([bool]$wrongPathProvenance.candidateClassProvenanceMatched) -Name "candidate provenance rejects class match on wrong file"
    $wrongPathReceipt = [pscustomobject]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        baseHead = $otherBase
        commitHash = $otherCommit
        candidateClassProvenance = $wrongPathProvenance
    }
    Assert-False -Condition (Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $wrongPathReceipt) -Name "snapshot-only wrong path is not positive learning evidence"

    $wrongMemberCandidate = [ordered]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        file = $javaPath
        member = "line-2"
        spacingAction = "collapse_extra_blank_line"
    }
    $wrongMemberProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodSourceBase `
        -CommitHash $methodCommit `
        -CandidateSnapshot $wrongMemberCandidate
    Assert-True -Condition ([bool]$wrongMemberProvenance.candidatePathMatched) -Name "wrong-member method spacing still matches candidate file"
    Assert-False -Condition ([bool]$wrongMemberProvenance.candidateMemberMatched) -Name "observed diff hunk must match candidate member"
    Assert-False -Condition ([bool]$wrongMemberProvenance.candidateClassProvenanceMatched) -Name "candidate provenance rejects class match on wrong hunk"

    $ancestorBaseReceipt = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $ancestorBaseReceipt.baseHead = $baseHead
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $ancestorBaseReceipt -ReceiptPath "ancestor-base-receipt.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected baseHead parent assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "baseHead mismatch") {
            throw
        }
        Write-Host "passed=receipt baseHead must equal source commit parent"
    }

    Assert-False -Condition ([bool]$validProvenance.discoveryEvidenceCreatedByCurrentProductPr) -Name "discovery evidence is not created by current product commit"
    Assert-True -Condition ([bool]$validProvenance.discoveryEvidenceCommitIsAncestorOfBaseHead) -Name "discovery evidence commit is ancestor of source baseHead"
    Assert-True -Condition ([bool]$validProvenance.discoveryEvidenceTrustRootVerified) -Name "pre-existing discovery evidence trust root is verified"

    $lateEvidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot "late-discovery-evidence" -CandidateId "canary-method-spacing-valid" -BaseHead $methodSourceBase
    $lateEvidence = New-ThresholdCandidateDiscoveryEvidence -BaseHead $methodSourceBase -CandidateId "canary-method-spacing-valid" -CandidatePocketPath $methodPocketPath
    Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $lateEvidence -Path $lateEvidencePath
    & git add -- $lateEvidencePath
    & git commit -m "Add late discovery evidence canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "late discovery evidence commit failed" }
    $lateEvidenceCommit = (& git rev-parse HEAD).Trim()
    $lateEvidenceProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodCommit `
        -PrBaseHead $methodSourceBase `
        -CommitHash $lateEvidenceCommit `
        -CandidatePocketPath $methodPocketPath `
        -DiscoveryEvidencePath $lateEvidencePath
    Assert-True -Condition ([bool]$lateEvidenceProvenance.discoveryEvidenceCreatedByCurrentProductPr) -Name "late discovery evidence is detected as current PR-created"
    Assert-True -Condition ([bool]$lateEvidenceProvenance.discoveryEvidenceChangedInsideProductPr) -Name "late discovery evidence is detected as PR-created"
    Assert-False -Condition ([bool]$lateEvidenceProvenance.discoveryEvidenceTrustRootVerified) -Name "late discovery evidence does not verify trust root"
    Assert-False -Condition ([bool]$lateEvidenceProvenance.candidateClassProvenanceMatched) -Name "evidence added inside product PR rejects provenance"
    Write-Host "passed=evidence_added_inside_product_pr"
    Write-Host "passed=evidence_commit_is_source_parent_but_not_pr_base_ancestor"
    $lateEvidenceReceipt = [pscustomobject]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        baseHead = $methodCommit
        commitHash = $lateEvidenceCommit
        candidateClassProvenance = $lateEvidenceProvenance
    }
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $lateEvidenceReceipt -ReceiptPath "late-discovery-evidence.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected late discovery evidence assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "PR baseHead|added or modified inside current product PR|candidateClassProvenanceMatched=false") {
            throw
        }
        Write-Host "passed=PR-added discovery evidence is rejected"
    }

    $beforeEvidenceModify = (& git rev-parse HEAD).Trim()
    $validEvidenceForModify = Get-Content -LiteralPath $validProvenance.discoveryEvidencePath -Raw | ConvertFrom-Json
    $validEvidenceForModify.candidateMember = "line-2"
    $validEvidenceForModify.candidateHunkFingerprint = Get-ThresholdStringSha256Lower -Text "candidatePath=$($validEvidenceForModify.candidatePath)`ncandidateMember=$($validEvidenceForModify.candidateMember)"
    $validEvidenceForModify.discoveryEvidenceDigest = Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $validEvidenceForModify
    Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $validEvidenceForModify -Path $validProvenance.discoveryEvidencePath
    & git add -- $validProvenance.discoveryEvidencePath
    & git commit -m "Modify referenced discovery evidence canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "discovery evidence modify commit failed" }
    $modifiedEvidenceCommit = (& git rev-parse HEAD).Trim()
    $modifiedEvidenceReceipt = $validReceipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $modifiedEvidenceReceipt.baseHead = $beforeEvidenceModify
    $modifiedEvidenceReceipt.commitHash = $modifiedEvidenceCommit
    $modifiedEvidenceReceipt.candidateClassProvenance.discoveryEvidenceDigest = $validEvidenceForModify.discoveryEvidenceDigest
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $modifiedEvidenceReceipt -ReceiptPath "modified-discovery-evidence.json" -CandidatePocketPath $methodPocketPath -PrBaseHead $methodSourceBase
        throw "Expected modified discovery evidence assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "added or modified inside current product PR|modified after PR baseHead|candidateClassProvenanceMatched=false") {
            throw
        }
        Write-Host "passed=PR-modified referenced discovery evidence is rejected"
        Write-Host "passed=evidence_modified_after_pr_base"
    }

    $insertPath = "src/main/java/org/example/InsertionBoundary.java"
    Write-CanaryFile -Path $insertPath -Lines @(
        "class InsertionBoundary {",
        "    void first() {",
        "    }",
        "    void second() {",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Add insertion boundary canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "insertion boundary base commit failed" }
    $insertBase = (& git rev-parse HEAD).Trim()
    Write-CanaryFile -Path $insertPath -Lines @(
        "class InsertionBoundary {",
        "    void first() {",
        "    }",
        "",
        "    void second() {",
        "    }",
        "}"
    )
    & git add .
    & git commit -m "Insert blank line at method boundary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "insertion boundary mutation commit failed" }
    $insertCommit = (& git rev-parse HEAD).Trim()
    Assert-True -Condition (Test-ThresholdObservedDiffMemberMatchesCandidate -BaseHead $insertBase -CommitHash $insertCommit -ProductPath $insertPath -CandidateMember "line-4") -Name "insert blank line at candidate boundary matches new range"
    Assert-False -Condition (Test-ThresholdObservedDiffMemberMatchesCandidate -BaseHead $insertBase -CommitHash $insertCommit -ProductPath $insertPath -CandidateMember "line-2") -Name "insert blank line at another method is rejected"

    $commentDiff = @(
        "diff --git a/src/main/java/org/example/Foo.java b/src/main/java/org/example/Foo.java",
        "index 1111111..2222222 100644",
        "--- a/src/main/java/org/example/Foo.java",
        "+++ b/src/main/java/org/example/Foo.java",
        "@@ -1,3 +1,4 @@",
        "-     * This comment line is long enough to require a conservative wrap.",
        "+     * This comment line is long enough",
        "+     * to require a conservative wrap."
    )
    Assert-True -Condition (Test-ThresholdCommentWrapDiff -DiffLines $commentDiff) -Name "comment wrap ignores git diff headers"

    $lineCommentDiff = @(
        "diff --git a/src/main/java/org/example/Foo.java b/src/main/java/org/example/Foo.java",
        "--- a/src/main/java/org/example/Foo.java",
        "+++ b/src/main/java/org/example/Foo.java",
        "-        // This line comment is long enough to require wrapping.",
        "+        // This line comment is long enough",
        "+        // to require wrapping."
    )
    Assert-True -Condition (Test-ThresholdLineCommentWrapDiff -DiffLines $lineCommentDiff) -Name "line comment wrap ignores git diff headers"

    $changedCommentDiff = @(
        "-     * This comment line is long enough to require a conservative wrap.",
        "+     * This different line is long enough",
        "+     * to require a conservative wrap."
    )
    Assert-False -Condition (Test-ThresholdCommentWrapDiff -DiffLines $changedCommentDiff) -Name "comment wrap rejects changed text"

    $changedLineCommentDiff = @(
        "-        // This line comment is long enough to require wrapping.",
        "+        // This different comment is long enough",
        "+        // to require wrapping."
    )
    Assert-False -Condition (Test-ThresholdLineCommentWrapDiff -DiffLines $changedLineCommentDiff) -Name "line comment wrap rejects changed text"

    $annotationDiff = @(
        "-    @RequestMapping(value = `"/owners`", method = RequestMethod.GET)",
        "+    @RequestMapping(",
        "+        value = `"/owners`",",
        "+        method = RequestMethod.GET",
        "+    )"
    )
    Assert-True -Condition (Test-ThresholdAnnotationAttributeWrapDiff -DiffLines $annotationDiff) -Name "annotation attribute wrap independently classified"

    $bootstrapDiff = @(
        "-        ApplicationBootstrap.start(`"petclinic`", `"web`");",
        "+        ApplicationBootstrap.start(",
        "+            `"petclinic`",",
        "+            `"web`"",
        "+        );"
    )
    Assert-True -Condition (Test-ThresholdBootstrapInvocationWrapDiff -DiffLines $bootstrapDiff) -Name "bootstrap invocation wrap accepts executor closing line"

    $changedBootstrapDiff = @(
        "-        ApplicationBootstrap.start(`"petclinic`", `"web`");",
        "+        ApplicationBootstrap.stop(",
        "+            `"other`",",
        "+            `"api`"",
        "+        );"
    )
    Assert-False -Condition (Test-ThresholdBootstrapInvocationWrapDiff -DiffLines $changedBootstrapDiff) -Name "bootstrap invocation wrap rejects changed invocation or arguments"

    $stringConstantDiff = @(
        "-    private static final String OWNER_QUERY = `"select owner from Owner owner where owner.lastName like :lastName`";",
        "+    private static final String OWNER_QUERY = `"select owner from Owner owner `" +",
        "+        `"where owner.lastName like :lastName`";"
    )
    Assert-True -Condition (Test-ThresholdStringConstantWrapDiff -DiffLines $stringConstantDiff) -Name "string constant wrap independently classified"

    $splitStringNormalizationDiff = @(
        "-    private static final String OWNER_QUERY = `"select owner `" + `"from Owner owner`";",
        "+    private static final String OWNER_QUERY = `"select owner `"",
        "+        + `"from Owner owner`";"
    )
    Assert-True -Condition (Test-ThresholdSplitStringConstantNormalizationDiff -DiffLines $splitStringNormalizationDiff) -Name "split string normalization matches executor output"

    $changedSplitStringNormalizationDiff = @(
        "-    private static final String OWNER_QUERY = `"select owner `" + `"from Owner owner`";",
        "+    private static final String OWNER_QUERY = `"select owner `"",
        "+        + `"from Pet pet`";"
    )
    Assert-False -Condition (Test-ThresholdSplitStringConstantNormalizationDiff -DiffLines $changedSplitStringNormalizationDiff) -Name "split string normalization rejects changed continuation value"

    $compoundImportSpacingDiff = @(
        " package org.example;",
        "-",
        " import java.util.Locale;",
        "-        return locale.toString();",
        "+        return locale.toLanguageTag();"
    )
    Assert-False -Condition (Test-ThresholdBlankLinePackageImportDiff -DiffLines $compoundImportSpacingDiff) -Name "import spacing rejects compound nonblank deltas"

    $compoundMethodSpacingDiff = @(
        "     }",
        "+",
        "     public String parse(String text) {",
        "-        return text;",
        "+        return text.trim();"
    )
    Assert-False -Condition (Test-ThresholdMethodSpacingDiff -DiffLines $compoundMethodSpacingDiff) -Name "method spacing rejects compound nonblank deltas"

    $leadingTabDiff = @(
        "-`treturn text;",
        "+    return text;"
    )
    Assert-True -Condition (Test-ThresholdLeadingTabIndentationDiff -DiffLines $leadingTabDiff) -Name "leading tab indentation classifier expands tabs on Windows PowerShell"

    $javaTextBlockLines = @(
        "class TextBlockCanary {",
        "    String query = `"`"`"",
        "`tSELECT *",
        "`tFROM owners",
        "    `"`"`";",
        "`tvoid normalize() {}",
        "}"
    )
    Assert-True -Condition (Test-ThresholdJavaLineIsInsideTextBlock -Lines $javaTextBlockLines -LineNumber 3) -Name "java text block state marks interior tab line"
    Assert-False -Condition (Test-ThresholdJavaLineIsInsideTextBlock -Lines $javaTextBlockLines -LineNumber 6) -Name "java text block state leaves ordinary tab line outside"

    $textBlockPath = "src/main/java/org/example/TextBlockCanary.java"
    Write-CanaryFile -Path $textBlockPath -Lines $javaTextBlockLines
    & git add .
    & git commit -m "Add text block tab canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "text block base commit failed" }
    $textBlockBase = (& git rev-parse HEAD).Trim()
    Write-CanaryFile -Path $textBlockPath -Lines @(
        "class TextBlockCanary {",
        "    String query = `"`"`"",
        "    SELECT *",
        "    FROM owners",
        "    `"`"`";",
        "`tvoid normalize() {}",
        "}"
    )
    & git add .
    & git commit -m "Normalize text block tabs only" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "text block mutation commit failed" }
    $textBlockCommit = (& git rev-parse HEAD).Trim()
    $textBlockDiffLines = @(& git diff --unified=3 "$textBlockBase..$textBlockCommit" -- $textBlockPath)
    Assert-False -Condition (Test-ThresholdLeadingTabIndentationDiff -DiffLines $textBlockDiffLines -BaseHead $textBlockBase -ProductPath $textBlockPath) -Name "leading tab classifier rejects text block content tabs"
    Assert-True -Condition ((Get-ThresholdIndependentlyObservedDiffClass -BaseHead $textBlockBase -CommitHash $textBlockCommit) -ne "leading_tab_indentation_cleanup") -Name "text block tab mutation is not independently classified as indentation cleanup"

    Write-CanaryFile -Path $textBlockPath -Lines @(
        "class TextBlockCanary {",
        "    String query = `"`"`"",
        "`tSELECT *",
        "`tFROM owners",
        "    `"`"`";",
        "    void anchor() {}",
        "`tvoid normalize() {}",
        "}"
    )
    & git add .
    & git commit -m "Add ordinary tab beside text block canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "mixed text block base commit failed" }
    $scriptRoot = Join-Path $PSScriptRoot "discover-candidates.ps1"
    $leasePath = "threshold/leases/current.yaml"
    Write-CanaryFile -Path $leasePath -Lines @(
        "leaseName: text-block-canary",
        "branch: main",
        "allowedCandidateTypes:",
        "  - leading_tab_indentation_cleanup"
    )
    $gatePath = "threshold/gates/auto-patchable-candidate-classes.json"
    Write-CanaryFile -Path $gatePath -Lines @(
        "{",
        "  `"approvedAutoPatchableCandidateClasses`": [",
        "    { `"candidateClass`": `"leading_tab_indentation_cleanup`" }",
        "  ]",
        "}"
    )
    $trainerPath = "threshold/trainer/training-report.json"
    Write-CanaryFile -Path $trainerPath -Lines @("{ `"decisions`": [] }")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptRoot -LeasePath $leasePath -PocketPath "threshold/candidate-pocket/current.json" -GatePath $gatePath -TrainerReportPath $trainerPath -SourceRoot "src/main/java" -Limit 10 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "discover-candidates text block canary failed" }
    $discoveredPocket = Get-Content -LiteralPath "threshold/candidate-pocket/current.json" -Raw | ConvertFrom-Json
    $leadingTabCandidates = @($discoveredPocket.candidates | Where-Object { [string]$_.candidateClass -eq "leading_tab_indentation_cleanup" })
    Assert-True -Condition ($leadingTabCandidates.Count -eq 1) -Name "discovery finds only the ordinary leading tab candidate beside text block"
    Assert-True -Condition ([string]$leadingTabCandidates[0].member -eq "line-7") -Name "discovery excludes text block tabs from leading tab candidate"
    Assert-True -Condition ([int]$leadingTabCandidates[0].lineCount -eq 1) -Name "discovery binds leading tab line count"

    & git add .
    & git commit -m "Materialize discovery evidence test pocket" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "discovery evidence pocket commit failed" }
    $mixedBase = (& git rev-parse HEAD).Trim()
    Write-CanaryFile -Path $textBlockPath -Lines @(
        "class TextBlockCanary {",
        "    String query = `"`"`"",
        "`tSELECT *",
        "`tFROM owners",
        "    `"`"`";",
        "    void anchor() {}",
        "    void normalize() {}",
        "}"
    )
    & git add .
    & git commit -m "Normalize ordinary leading tab canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ordinary leading tab mutation commit failed" }
    $leadingTabCommit = (& git rev-parse HEAD).Trim()
    $leadingTabCandidate = [ordered]@{
        candidateId = "canary-leading-tab-valid"
        candidateClass = "leading_tab_indentation_cleanup"
        file = $textBlockPath
        member = "line-7"
        lineCount = 1
    }
    $leadingTabProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-leading-tab-valid" `
        -GrantedCandidateClass "leading_tab_indentation_cleanup" `
        -ExecutorCandidateClass "leading_tab_indentation_cleanup" `
        -ReceiptCandidateClass "leading_tab_indentation_cleanup" `
        -LearningProjectionClass "leading_tab_indentation_cleanup" `
        -BaseHead $mixedBase `
        -CommitHash $leadingTabCommit `
        -CandidateSnapshot $leadingTabCandidate
    Assert-True -Condition ([bool]$leadingTabProvenance.candidateExecutionParametersMatched) -Name "leading tab correct lineCount matches observed diff"

    $wrongLineCountCandidate = [ordered]@{
        candidateId = "canary-leading-tab-valid"
        candidateClass = "leading_tab_indentation_cleanup"
        file = $textBlockPath
        member = "line-7"
        lineCount = 2
    }
    $wrongLineCountProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-leading-tab-valid" `
        -GrantedCandidateClass "leading_tab_indentation_cleanup" `
        -ExecutorCandidateClass "leading_tab_indentation_cleanup" `
        -ReceiptCandidateClass "leading_tab_indentation_cleanup" `
        -LearningProjectionClass "leading_tab_indentation_cleanup" `
        -BaseHead $mixedBase `
        -CommitHash $leadingTabCommit `
        -CandidateSnapshot $wrongLineCountCandidate
    Assert-False -Condition ([bool]$wrongLineCountProvenance.candidateExecutionParametersMatched) -Name "leading tab mismatched lineCount is rejected"
    Assert-False -Condition ([bool]$wrongLineCountProvenance.candidateClassProvenanceMatched) -Name "leading tab wrong execution parameter blocks provenance"

    $changedLiteralDiff = @(
        "-    private static final String OWNER_QUERY = `"foo bar`";",
        "+    private static final String OWNER_QUERY = `"different `" +",
        "+        `"value`";"
    )
    Assert-False -Condition (Test-ThresholdStringConstantWrapDiff -DiffLines $changedLiteralDiff) -Name "string constant wrap rejects changed literal value"

    $changedAnnotationDiff = @(
        "-    @RequestMapping(value = `"/owners`", method = RequestMethod.GET)",
        "+    @RequestMapping(",
        "+        value = `"/pets`",",
        "+        method = RequestMethod.GET",
        "+    )"
    )
    Assert-False -Condition (Test-ThresholdAnnotationAttributeWrapDiff -DiffLines $changedAnnotationDiff) -Name "annotation attribute wrap rejects changed argument values"

    $changedAnnotationWhitespaceLiteralDiff = @(
        "-    @RequestMapping(value = `"/owners  active`", method = RequestMethod.GET)",
        "+    @RequestMapping(",
        "+        value = `"/owners active`",",
        "+        method = RequestMethod.GET",
        "+    )"
    )
    Assert-False -Condition (Test-ThresholdAnnotationAttributeWrapDiff -DiffLines $changedAnnotationWhitespaceLiteralDiff) -Name "annotation attribute wrap preserves string literal whitespace"

    Assert-True -Condition (Test-ThresholdCandidateClassHasIndependentDiffClassifier -CandidateClass "annotation_attribute_wrap_cleanup") -Name "annotation auto patch class has independent classifier"
    Assert-True -Condition (Test-ThresholdCandidateClassHasIndependentDiffClassifier -CandidateClass "string_constant_wrap_cleanup") -Name "string constant auto patch class has independent classifier"
    Assert-False -Condition (Test-ThresholdCandidateClassHasIndependentDiffClassifier -CandidateClass "repository_readability_cleanup") -Name "unsupported auto patch class is not selected without independent classifier"

    $batchReceipt = [pscustomobject]@{
        batchId = "batch-canary"
        sourceCommit = $commitHash
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $batchReceipt -ReceiptPath "batch-receipt.json"
    Assert-False -Condition (Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $batchReceipt) -Name "batch receipt without provenance remains compatible but not positive learning evidence"

    $injectedBatchReceipt = [pscustomobject]@{
        batchId = "batch-canary"
        sourceCommit = $methodCommit
        candidateClassProvenance = $validProvenance
    }
    Assert-False -Condition (Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $injectedBatchReceipt) -Name "batch receipt with injected provenance cannot establish positive learning"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $injectedBatchReceipt -ReceiptPath "injected-batch-receipt.json"
        throw "Expected batch provenance assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "batch receipt cannot establish positive learning without candidateId") {
            throw
        }
        Write-Host "passed=batch receipt provenance requires candidate-bound recompute"
    }

    Write-Host "candidateClassProvenanceTests=passed"
}
finally {
    Set-Location $originalLocation
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
