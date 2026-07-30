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
        "    String print(Locale locale) {",
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

    Write-CanaryFile -Path $javaPath -Lines @(
        "package org.example;",
        "",
        "import java.util.Locale;",
        "",
        "class PetTypeFormatter {",
        "    String print(Locale locale) {",
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
    Assert-ThresholdCandidateClassProvenance -Receipt ([pscustomobject]@{ candidateClassProvenance = $validProvenance }) -ReceiptPath "valid-receipt.json"
    Write-Host "passed=positive provenance receipt is admitted"

    Write-Host "candidateClassProvenanceTests=passed"
}
finally {
    Set-Location $originalLocation
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
