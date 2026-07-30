[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-ThresholdJsonProperty {
    param([object] $Object, [string] $Name, [object] $DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $DefaultValue
}

function ConvertTo-ThresholdRepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function Get-ThresholdStringSha256Lower {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-ThresholdBlankLinePackageImportDiff {
    param([string[]] $DiffLines)

    $removedBlank = @($DiffLines | Where-Object { $_ -eq "-" }).Count
    $addedBlank = @($DiffLines | Where-Object { $_ -eq "+" }).Count
    $packageContext = @($DiffLines | Where-Object { $_ -match '^[ +\-]package\s+[\w.]+;' }).Count -gt 0
    $importContext = @($DiffLines | Where-Object { $_ -match '^[ +\-]import\s+[\w.*]+;' }).Count -gt 0
    return ($removedBlank + $addedBlank) -gt 0 -and $packageContext -and $importContext
}

function Test-ThresholdMethodSpacingDiff {
    param([string[]] $DiffLines)

    $blankDelta = @($DiffLines | Where-Object { $_ -eq "-" -or $_ -eq "+" }).Count
    if ($blankDelta -ne 1) { return $false }
    $hasClosingBrace = @($DiffLines | Where-Object { $_ -match '^[ +\-]\s*\}\s*$' }).Count -gt 0
    $hasMethodOrAnnotation = @($DiffLines | Where-Object { $_ -match '^[ +\-]\s*(?:@|public\b|private\b|protected\b)' }).Count -gt 0
    return $hasClosingBrace -and $hasMethodOrAnnotation
}

function Get-ThresholdDiffContentLines {
    param([string[]] $DiffLines)

    return @($DiffLines | Where-Object {
        $_ -notmatch '^(diff --git |index |\-\-\- |\+\+\+ |@@ )'
    })
}

function Test-ThresholdCommentWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*\*\s+\S' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*\*\s+\S' })
    $nonCommentDelta = @($contentLines | Where-Object {
        ($_ -match '^[+-]' -and $_ -notmatch '^[+-]\s*\*\s+\S')
    })
    return $removed.Count -eq 1 -and $added.Count -eq 2 -and $nonCommentDelta.Count -eq 0
}

function Test-ThresholdLineCommentWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*//\s+\S' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*//\s+\S' })
    $nonCommentDelta = @($contentLines | Where-Object {
        ($_ -match '^[+-]' -and $_ -notmatch '^[+-]\s*//\s+\S')
    })
    return $removed.Count -eq 1 -and $added.Count -eq 2 -and $nonCommentDelta.Count -eq 0
}

function Test-ThresholdStringConstantWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*private static final String [A-Z0-9_]+ = "[^"\\]+";\s*$' })
    $addedStart = @($contentLines | Where-Object { $_ -match '^\+\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s*$' })
    $addedEnd = @($contentLines | Where-Object { $_ -match '^\+\s*"[^"\\]+";\s*$' })
    $nonStringDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*private static final String [A-Z0-9_]+ = "[^"\\]+"(?: \+)?;?\s*$' -and
        $_ -notmatch '^[+-]\s*"[^"\\]+";\s*$'
    })
    return $removed.Count -eq 1 -and $addedStart.Count -eq 1 -and $addedEnd.Count -eq 1 -and $nonStringDelta.Count -eq 0
}

function Test-ThresholdSplitStringConstantNormalizationDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removedStart = @($contentLines | Where-Object { $_ -match '^-\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s*$' })
    $removedEnd = @($contentLines | Where-Object { $_ -match '^-\s*"[^"\\]+";\s*$' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*private static final String [A-Z0-9_]+ = "[^"\\]+";\s*$' })
    $nonStringDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*private static final String [A-Z0-9_]+ = "[^"\\]+"(?: \+)?;?\s*$' -and
        $_ -notmatch '^[+-]\s*"[^"\\]+";\s*$'
    })
    return $removedStart.Count -eq 1 -and $removedEnd.Count -eq 1 -and $added.Count -eq 1 -and $nonStringDelta.Count -eq 0
}

function Test-ThresholdAnnotationAttributeWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*@[A-Za-z][A-Za-z0-9_.]*\(.+\)\s*$' })
    $addedOpen = @($contentLines | Where-Object { $_ -match '^\+\s*@[A-Za-z][A-Za-z0-9_.]*\(\s*$' })
    $addedArgs = @($contentLines | Where-Object { $_ -match '^\+\s+[A-Za-z_][A-Za-z0-9_]*\s*=.+,?\s*$' })
    $addedClose = @($contentLines | Where-Object { $_ -match '^\+\s*\)\s*$' })
    $nonAnnotationDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*@[A-Za-z][A-Za-z0-9_.]*\(.*\)?\s*$' -and
        $_ -notmatch '^[+-]\s+[A-Za-z_][A-Za-z0-9_]*\s*=.+,?\s*$' -and
        $_ -notmatch '^[+-]\s*\)\s*$'
    })
    return $removed.Count -eq 1 -and $addedOpen.Count -eq 1 -and $addedArgs.Count -ge 2 -and $addedClose.Count -eq 1 -and $nonAnnotationDelta.Count -eq 0
}

function Test-ThresholdBootstrapInvocationWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*[A-Za-z0-9_.]+\(\s*"[^"\\]+"\s*(,\s*"[^"\\]+"\s*)+\);\s*$' })
    $addedOpen = @($contentLines | Where-Object { $_ -match '^\+\s*[A-Za-z0-9_.]+\(\s*$' })
    $addedArgs = @($contentLines | Where-Object { $_ -match '^\+\s+"[^"\\]+"[,]?\s*$' })
    $addedClose = @($contentLines | Where-Object { $_ -match '^\+\s*\);\s*$' })
    $nonBootstrapDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*[A-Za-z0-9_.]+\(\s*(?:"[^"\\]+"\s*(?:,\s*"[^"\\]+"\s*)+)?\)?;?\s*$' -and
        $_ -notmatch '^[+-]\s+"[^"\\]+"[,]?\s*$'
    })
    return $removed.Count -eq 1 -and $addedOpen.Count -eq 1 -and $addedArgs.Count -ge 2 -and $addedClose.Count -eq 1 -and $nonBootstrapDelta.Count -eq 0
}

function Test-ThresholdLeadingTabIndentationDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match "^-\t+\S" })
    $added = @($contentLines | Where-Object { $_ -match '^\+ {4,}\S' })
    if ($removed.Count -eq 0 -or $removed.Count -ne $added.Count) { return $false }
    $nonIndentDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and $_ -notmatch "^-\t+\S" -and $_ -notmatch '^\+ {4,}\S'
    })
    if ($nonIndentDelta.Count -ne 0) { return $false }
    for ($i = 0; $i -lt $removed.Count; $i++) {
        $normalizedRemoved = ($removed[$i].Substring(1) -replace "^\t+", { param($m) return " " * (4 * $m.Value.Length) })
        $normalizedAdded = $added[$i].Substring(1)
        if ($normalizedRemoved -ne $normalizedAdded) { return $false }
    }
    return $true
}

function Get-ThresholdIndependentlyClassifiedCandidateClasses {
    return @(
        "annotation_attribute_wrap_cleanup",
        "application_bootstrap_readability_cleanup",
        "comment_wrap_cleanup",
        "import_spacing_normalization",
        "leading_tab_indentation_cleanup",
        "line_comment_wrap_cleanup",
        "method_spacing_normalization",
        "split_string_constant_normalization",
        "string_constant_wrap_cleanup"
    )
}

function Test-ThresholdCandidateClassHasIndependentDiffClassifier {
    param([string] $CandidateClass)
    return [string]$CandidateClass -in @(Get-ThresholdIndependentlyClassifiedCandidateClasses)
}

function Get-ThresholdIndependentlyObservedDiffClass {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash
    )

    $paths = @(& git diff --name-only "$BaseHead..$CommitHash" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $productPaths = @($paths | Where-Object { $_ -like "src/main/java/*.java" -or $_ -like "src/main/java/**/*.java" })
    if ($productPaths.Count -ne 1 -or $paths.Count -ne 1) {
        return "compound_or_governance_diff"
    }

    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $productPaths[0])
    if (Test-ThresholdBlankLinePackageImportDiff -DiffLines $diffLines) {
        return "import_spacing_normalization"
    }
    if (Test-ThresholdMethodSpacingDiff -DiffLines $diffLines) {
        return "method_spacing_normalization"
    }
    if (Test-ThresholdStringConstantWrapDiff -DiffLines $diffLines) {
        return "string_constant_wrap_cleanup"
    }
    if (Test-ThresholdSplitStringConstantNormalizationDiff -DiffLines $diffLines) {
        return "split_string_constant_normalization"
    }
    if (Test-ThresholdCommentWrapDiff -DiffLines $diffLines) {
        return "comment_wrap_cleanup"
    }
    if (Test-ThresholdLineCommentWrapDiff -DiffLines $diffLines) {
        return "line_comment_wrap_cleanup"
    }
    if (Test-ThresholdBootstrapInvocationWrapDiff -DiffLines $diffLines) {
        return "application_bootstrap_readability_cleanup"
    }
    if (Test-ThresholdAnnotationAttributeWrapDiff -DiffLines $diffLines) {
        return "annotation_attribute_wrap_cleanup"
    }
    if (Test-ThresholdLeadingTabIndentationDiff -DiffLines $diffLines) {
        return "leading_tab_indentation_cleanup"
    }
    return "unknown"
}

function Get-ThresholdCandidateFromPocket {
    param([string] $CandidatePocketPath, [string] $CandidateId)
    if ([string]::IsNullOrWhiteSpace($CandidatePocketPath) -or -not (Test-Path $CandidatePocketPath)) {
        return $null
    }
    $pocket = Get-Content $CandidatePocketPath -Raw | ConvertFrom-Json
    return @($pocket.candidates | Where-Object { [string]$_.candidateId -eq $CandidateId } | Select-Object -First 1)
}

function New-ThresholdCandidateClassProvenance {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CandidateId,
        [Parameter(Mandatory = $true)]
        [string] $GrantedCandidateClass,
        [Parameter(Mandatory = $true)]
        [string] $ExecutorCandidateClass,
        [Parameter(Mandatory = $true)]
        [string] $ReceiptCandidateClass,
        [Parameter(Mandatory = $true)]
        [string] $LearningProjectionClass,
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash,
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json"
    )

    $candidate = Get-ThresholdCandidateFromPocket -CandidatePocketPath $CandidatePocketPath -CandidateId $CandidateId
    $discoveryRuleId = $null
    $discoveredCandidateClass = $null
    if ($candidate) {
        $discoveredCandidateClass = [string]$candidate.candidateClass
        $discoveryRuleId = "static-heuristic-scan:$discoveredCandidateClass"
    }
    $observedDiffClass = Get-ThresholdIndependentlyObservedDiffClass -BaseHead $BaseHead -CommitHash $CommitHash
    $chain = @(
        $discoveredCandidateClass,
        $GrantedCandidateClass,
        $ExecutorCandidateClass,
        $observedDiffClass,
        $ReceiptCandidateClass,
        $LearningProjectionClass
    )
    $matched = -not [string]::IsNullOrWhiteSpace($discoveredCandidateClass)
    foreach ($value in $chain) {
        if ([string]::IsNullOrWhiteSpace([string]$value) -or [string]$value -ne [string]$GrantedCandidateClass) {
            $matched = $false
        }
    }

    $basis = @(
        "candidateId=$CandidateId",
        "discoveryRuleId=$discoveryRuleId",
        "discoveredCandidateClass=$discoveredCandidateClass",
        "grantedCandidateClass=$GrantedCandidateClass",
        "executorCandidateClass=$ExecutorCandidateClass",
        "independentlyObservedDiffClass=$observedDiffClass",
        "receiptCandidateClass=$ReceiptCandidateClass",
        "learningProjectionClass=$LearningProjectionClass",
        "baseHead=$BaseHead",
        "commitHash=$CommitHash"
    )

    return [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-class-provenance.v0.1"
        discoveryObservation = if ($candidate) { "candidate-pocket" } else { "missing" }
        discoveryRuleId = $discoveryRuleId
        discoveryCandidateId = $CandidateId
        discoveredCandidateClass = $discoveredCandidateClass
        grantedCandidateClass = $GrantedCandidateClass
        executorCandidateClass = $ExecutorCandidateClass
        independentlyObservedDiffClass = $observedDiffClass
        receiptCandidateClass = $ReceiptCandidateClass
        learningProjectionClass = $LearningProjectionClass
        candidateClassProvenanceMatched = [bool]$matched
        productMutationAdmission = [bool]$matched
        receiptAdmission = [bool]$matched
        kgMaterialization = [bool]$matched
        trainerMaterialization = [bool]$matched
        publicationAdmission = [bool]$matched
        readyAdmission = [bool]$matched
        mergeAdmission = [bool]$matched
        promotionEvidenceContribution = [bool]$matched
        provenanceDigest = Get-ThresholdStringSha256Lower -Text ([string]::Join("`n", $basis))
    }
}

function Assert-ThresholdCandidateClassProvenance {
    param([pscustomobject] $Receipt, [string] $ReceiptPath = "", [switch] $RequirePresent)

    $provenance = Get-ThresholdJsonProperty $Receipt "candidateClassProvenance" $null
    if ($null -eq $provenance) {
        if ($RequirePresent.IsPresent) {
            throw "candidateClassProvenance missing receipt=$ReceiptPath"
        }
        return
    }
    if ((Get-ThresholdJsonProperty $provenance "candidateClassProvenanceMatched" $false) -ne $true) {
        throw "candidateClassProvenanceMatched=false receipt=$ReceiptPath observedDiffClass=$($provenance.independentlyObservedDiffClass) receiptCandidateClass=$($provenance.receiptCandidateClass)"
    }
    foreach ($field in @("productMutationAdmission", "receiptAdmission", "kgMaterialization", "trainerMaterialization", "publicationAdmission", "readyAdmission", "mergeAdmission", "promotionEvidenceContribution")) {
        if ((Get-ThresholdJsonProperty $provenance $field $false) -ne $true) {
            throw "candidateClassProvenance admission field failed: $field receipt=$ReceiptPath"
        }
    }
}

function Test-ThresholdCandidateClassProvenancePositiveLearningEligible {
    param([pscustomobject] $Receipt)

    $provenance = Get-ThresholdJsonProperty $Receipt "candidateClassProvenance" $null
    if ($null -eq $provenance) {
        return $false
    }
    if ((Get-ThresholdJsonProperty $provenance "candidateClassProvenanceMatched" $false) -ne $true) {
        return $false
    }
    foreach ($field in @("kgMaterialization", "trainerMaterialization", "promotionEvidenceContribution")) {
        if ((Get-ThresholdJsonProperty $provenance $field $false) -ne $true) {
            return $false
        }
    }
    return $true
}
