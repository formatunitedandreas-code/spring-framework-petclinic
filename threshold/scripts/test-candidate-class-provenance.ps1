[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")

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

    $methodPocket = [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
        generatedFromHead = $methodBase
        candidates = @(
            [ordered]@{
                candidateId = "canary-method-spacing-valid"
                candidateClass = "method_spacing_normalization"
                file = $javaPath
                member = "line-9"
            }
        )
    }
    $methodPocketPath = "method-pocket.json"
    $methodPocket | ConvertTo-Json -Depth 6 | Set-Content $methodPocketPath

    $validProvenance = New-ThresholdCandidateClassProvenance `
        -CandidateId "canary-method-spacing-valid" `
        -GrantedCandidateClass "method_spacing_normalization" `
        -ExecutorCandidateClass "method_spacing_normalization" `
        -ReceiptCandidateClass "method_spacing_normalization" `
        -LearningProjectionClass "method_spacing_normalization" `
        -BaseHead $methodBase `
        -CommitHash $methodCommit `
        -CandidatePocketPath $methodPocketPath

    Assert-True -Condition ($validProvenance.independentlyObservedDiffClass -eq "method_spacing_normalization") -Name "method spacing independently classified"
    Assert-True -Condition ([bool]$validProvenance.candidateClassProvenanceMatched) -Name "matching method spacing provenance is admitted"
    $validReceipt = [pscustomobject]@{
        candidateId = "canary-method-spacing-valid"
        candidateClass = "method_spacing_normalization"
        baseHead = $methodBase
        commitHash = $methodCommit
        candidateClassProvenance = $validProvenance
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $validReceipt -ReceiptPath "valid-receipt.json" -CandidatePocketPath $methodPocketPath
    Write-Host "passed=positive provenance receipt is admitted"

    $receiptClassTamper = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $receiptClassTamper.candidateClass = "import_spacing_normalization"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $receiptClassTamper -ReceiptPath "receipt-class-tamper.json" -CandidatePocketPath $methodPocketPath
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
    Assert-ThresholdCandidateClassProvenance -Receipt $validReceipt -ReceiptPath "receipt-bound-pocket.json" -CandidatePocketPath $stalePocketPath
    Write-Host "passed=receipt-bound execution snapshot validates without mutable current pocket"

    $snapshotDigestTamper = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $snapshotDigestTamper.candidateClassProvenance.executionCandidateSnapshot.member = "line-99"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $snapshotDigestTamper -ReceiptPath "snapshot-digest-tamper.json" -CandidatePocketPath $stalePocketPath
        throw "Expected receipt-bound snapshot digest assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "execution snapshot digest mismatch") {
            throw
        }
        Write-Host "passed=receipt-bound execution snapshot digest is immutable"
    }

    $staleReceipt = $validReceipt | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $staleReceipt.candidateClassProvenance.provenanceDigest = "stale"
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $staleReceipt -ReceiptPath "stale-receipt.json" -CandidatePocketPath $methodPocketPath
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
        baseHead = $methodBase
        sourceCommit = $methodCommit
        candidateClassProvenance = $validProvenance
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $sourceCommitReceipt -ReceiptPath "source-commit-receipt.json" -CandidatePocketPath $methodPocketPath
    Write-Host "passed=sourceCommit provenance is recomputed and admitted"

    $ancestorBaseReceipt = $validReceipt | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $ancestorBaseReceipt.baseHead = $baseHead
    try {
        Assert-ThresholdCandidateClassProvenance -Receipt $ancestorBaseReceipt -ReceiptPath "ancestor-base-receipt.json" -CandidatePocketPath $methodPocketPath
        throw "Expected baseHead parent assertion failure did not occur."
    }
    catch {
        if ($_.Exception.Message -notmatch "baseHead mismatch") {
            throw
        }
        Write-Host "passed=receipt baseHead must equal source commit parent"
    }

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
