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

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $deltaLines = @($contentLines | Where-Object { $_ -match '^[+-]' })
    $removedBlank = @($deltaLines | Where-Object { $_ -eq "-" }).Count
    $addedBlank = @($deltaLines | Where-Object { $_ -eq "+" }).Count
    $packageContext = @($contentLines | Where-Object { $_ -match '^[ +\-]package\s+[\w.]+;' }).Count -gt 0
    $importContext = @($contentLines | Where-Object { $_ -match '^[ +\-]import\s+[\w.*]+;' }).Count -gt 0
    return ($removedBlank + $addedBlank) -gt 0 -and
        $deltaLines.Count -eq ($removedBlank + $addedBlank) -and
        $packageContext -and
        $importContext
}

function Test-ThresholdMethodSpacingDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $deltaLines = @($contentLines | Where-Object { $_ -match '^[+-]' })
    $blankDelta = @($deltaLines | Where-Object { $_ -eq "-" -or $_ -eq "+" }).Count
    if ($blankDelta -ne 1) { return $false }
    $hasClosingBrace = @($contentLines | Where-Object { $_ -match '^[ +\-]\s*\}\s*$' }).Count -gt 0
    $hasMethodOrAnnotation = @($contentLines | Where-Object { $_ -match '^[ +\-]\s*(?:@|public\b|private\b|protected\b)' }).Count -gt 0
    return $deltaLines.Count -eq $blankDelta -and $hasClosingBrace -and $hasMethodOrAnnotation
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
    if ($removed.Count -ne 1 -or $added.Count -ne 2 -or $nonCommentDelta.Count -ne 0) {
        return $false
    }
    $removedText = ConvertTo-ThresholdCollapsedWhitespace ((Get-ThresholdCommentPayload -Line $removed[0] -PrefixPattern '^[+-]\s*\*\s*'))
    $addedText = ConvertTo-ThresholdCollapsedWhitespace (($added | ForEach-Object { Get-ThresholdCommentPayload -Line $_ -PrefixPattern '^[+-]\s*\*\s*' }) -join " ")
    return $removedText -eq $addedText
}

function Test-ThresholdLineCommentWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*//\s+\S' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*//\s+\S' })
    $nonCommentDelta = @($contentLines | Where-Object {
        ($_ -match '^[+-]' -and $_ -notmatch '^[+-]\s*//\s+\S')
    })
    if ($removed.Count -ne 1 -or $added.Count -ne 2 -or $nonCommentDelta.Count -ne 0) {
        return $false
    }
    $removedText = ConvertTo-ThresholdCollapsedWhitespace ((Get-ThresholdCommentPayload -Line $removed[0] -PrefixPattern '^[+-]\s*//\s*'))
    $addedText = ConvertTo-ThresholdCollapsedWhitespace (($added | ForEach-Object { Get-ThresholdCommentPayload -Line $_ -PrefixPattern '^[+-]\s*//\s*' }) -join " ")
    return $removedText -eq $addedText
}

function Test-ThresholdStringConstantWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)";\s*$' })
    $addedStart = @($contentLines | Where-Object { $_ -match '^\+\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)" \+\s*$' })
    $addedEnd = @($contentLines | Where-Object { $_ -match '^\+\s*"(?<value>[^"\\]+)";\s*$' })
    $nonStringDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*private static final String [A-Z0-9_]+ = "[^"\\]+"(?: \+)?;?\s*$' -and
        $_ -notmatch '^[+-]\s*"[^"\\]+";\s*$'
    })
    if ($removed.Count -ne 1 -or $addedStart.Count -ne 1 -or $addedEnd.Count -ne 1 -or $nonStringDelta.Count -ne 0) {
        return $false
    }
    $removedMatch = [regex]::Match($removed[0], '^-\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)";\s*$')
    $addedStartMatch = [regex]::Match($addedStart[0], '^\+\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)" \+\s*$')
    $addedEndMatch = [regex]::Match($addedEnd[0], '^\+\s*"(?<value>[^"\\]+)";\s*$')
    return $removedMatch.Groups["name"].Value -eq $addedStartMatch.Groups["name"].Value -and
        $removedMatch.Groups["value"].Value -eq ($addedStartMatch.Groups["value"].Value + $addedEndMatch.Groups["value"].Value)
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
    if ($removedStart.Count -ne 1 -or $removedEnd.Count -ne 1 -or $added.Count -ne 1 -or $nonStringDelta.Count -ne 0) {
        return $false
    }
    $removedStartMatch = [regex]::Match($removedStart[0], '^-\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)" \+\s*$')
    $removedEndMatch = [regex]::Match($removedEnd[0], '^-\s*"(?<value>[^"\\]+)";\s*$')
    $addedMatch = [regex]::Match($added[0], '^\+\s*private static final String (?<name>[A-Z0-9_]+) = "(?<value>[^"\\]+)";\s*$')
    return $removedStartMatch.Groups["name"].Value -eq $addedMatch.Groups["name"].Value -and
        ($removedStartMatch.Groups["value"].Value + $removedEndMatch.Groups["value"].Value) -eq $addedMatch.Groups["value"].Value
}

function Split-ThresholdTopLevelCommaArguments {
    param([string] $Text)

    $parts = New-Object System.Collections.Generic.List[string]
    $start = 0
    $depth = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($char -eq '\') {
                $escaped = $true
                continue
            }
            if ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            continue
        }
        if ($char -eq '(' -or $char -eq '{' -or $char -eq '[') {
            $depth++
            continue
        }
        if ($char -eq ')' -or $char -eq '}' -or $char -eq ']') {
            if ($depth -gt 0) { $depth-- }
            continue
        }
        if ($char -eq ',' -and $depth -eq 0) {
            $parts.Add($Text.Substring($start, $i - $start).Trim())
            $start = $i + 1
        }
    }

    $parts.Add($Text.Substring($start).Trim())
    return @($parts.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertTo-ThresholdNormalizedAnnotationArgument {
    param([string] $Text)
    return ConvertTo-ThresholdWhitespaceNormalizedOutsideStringLiteral -Text ($Text.Trim().TrimEnd(","))
}

function ConvertTo-ThresholdCollapsedWhitespace {
    param([string] $Text)
    return ([regex]::Replace($Text.Trim(), '\s+', ' '))
}

function Get-ThresholdCommentPayload {
    param([string] $Line, [string] $PrefixPattern)
    return ([regex]::Replace($Line, $PrefixPattern, "")).Trim()
}

function ConvertTo-ThresholdWhitespaceNormalizedOutsideStringLiteral {
    param([string] $Text)

    $builder = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false
    $pendingSpace = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($inString) {
            [void]$builder.Append($char)
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($char -eq '\') {
                $escaped = $true
                continue
            }
            if ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            if ($pendingSpace -and $builder.Length -gt 0) {
                [void]$builder.Append(" ")
            }
            $pendingSpace = $false
            $inString = $true
            [void]$builder.Append($char)
            continue
        }
        if ([char]::IsWhiteSpace($char)) {
            $pendingSpace = $true
            continue
        }
        if ($pendingSpace -and $builder.Length -gt 0) {
            [void]$builder.Append(" ")
        }
        $pendingSpace = $false
        [void]$builder.Append($char)
    }

    return $builder.ToString().Trim()
}

function Test-ThresholdAnnotationAttributeWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*@(?<name>[A-Za-z][A-Za-z0-9_.]*)\((?<args>.+)\)\s*$' })
    $addedOpen = @($contentLines | Where-Object { $_ -match '^\+\s*@(?<name>[A-Za-z][A-Za-z0-9_.]*)\(\s*$' })
    $addedArgs = @($contentLines | Where-Object { $_ -match '^\+\s+[A-Za-z_][A-Za-z0-9_]*\s*=.+,?\s*$' })
    $addedClose = @($contentLines | Where-Object { $_ -match '^\+\s*\)\s*$' })
    $nonAnnotationDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*@[A-Za-z][A-Za-z0-9_.]*\(.*\)?\s*$' -and
        $_ -notmatch '^[+-]\s+[A-Za-z_][A-Za-z0-9_]*\s*=.+,?\s*$' -and
        $_ -notmatch '^[+-]\s*\)\s*$'
    })
    if ($removed.Count -ne 1 -or $addedOpen.Count -ne 1 -or $addedArgs.Count -lt 2 -or $addedClose.Count -ne 1 -or $nonAnnotationDelta.Count -ne 0) {
        return $false
    }

    $removedMatch = [regex]::Match($removed[0], '^-\s*@(?<name>[A-Za-z][A-Za-z0-9_.]*)\((?<args>.+)\)\s*$')
    $addedOpenMatch = [regex]::Match($addedOpen[0], '^\+\s*@(?<name>[A-Za-z][A-Za-z0-9_.]*)\(\s*$')
    if ($removedMatch.Groups["name"].Value -ne $addedOpenMatch.Groups["name"].Value) {
        return $false
    }
    $removedArgs = @(Split-ThresholdTopLevelCommaArguments -Text $removedMatch.Groups["args"].Value | ForEach-Object {
        ConvertTo-ThresholdNormalizedAnnotationArgument -Text $_
    })
    $addedNormalizedArgs = @($addedArgs | ForEach-Object {
        ConvertTo-ThresholdNormalizedAnnotationArgument -Text ($_.Substring(1))
    })
    return ($removedArgs -join "`n") -eq ($addedNormalizedArgs -join "`n")
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
        $_ -notmatch '^[+-]\s+"[^"\\]+"[,]?\s*$' -and
        $_ -notmatch '^\+\s*\);\s*$'
    })
    if ($removed.Count -ne 1 -or $addedOpen.Count -ne 1 -or $addedArgs.Count -lt 2 -or $addedClose.Count -ne 1 -or $nonBootstrapDelta.Count -ne 0) {
        return $false
    }
    $removedMatch = [regex]::Match($removed[0], '^-\s*(?<invocation>[A-Za-z0-9_.]+)\(\s*(?<args>"[^"\\]+"\s*(,\s*"[^"\\]+"\s*)+)\);\s*$')
    $addedOpenMatch = [regex]::Match($addedOpen[0], '^\+\s*(?<invocation>[A-Za-z0-9_.]+)\(\s*$')
    if ($removedMatch.Groups["invocation"].Value -ne $addedOpenMatch.Groups["invocation"].Value) {
        return $false
    }
    $removedArgs = @([regex]::Matches($removedMatch.Groups["args"].Value, '"(?:[^"\\]|\\.)*"') | ForEach-Object { $_.Value })
    $addedArgValues = @($addedArgs | ForEach-Object {
        [regex]::Match($_, '^\+\s*(?<arg>"(?:[^"\\]|\\.)*")[,]?\s*$').Groups["arg"].Value
    })
    return ($removedArgs -join "`n") -eq ($addedArgValues -join "`n")
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

function New-ThresholdCandidateSnapshot {
    param([object] $Candidate)
    if ($null -eq $Candidate) { return $null }
    return [ordered]@{
        candidateId = [string](Get-ThresholdJsonProperty $Candidate "candidateId" "")
        candidateClass = [string](Get-ThresholdJsonProperty $Candidate "candidateClass" "")
        file = [string](Get-ThresholdJsonProperty $Candidate "file" "")
        member = [string](Get-ThresholdJsonProperty $Candidate "member" "")
    }
}

function Get-ThresholdCandidateSnapshotDigest {
    param([object] $CandidateSnapshot)
    if ($null -eq $CandidateSnapshot) { return "" }
    $candidateId = [string](Get-ThresholdJsonProperty $CandidateSnapshot "candidateId" "")
    $candidateClass = [string](Get-ThresholdJsonProperty $CandidateSnapshot "candidateClass" "")
    $file = [string](Get-ThresholdJsonProperty $CandidateSnapshot "file" "")
    $member = [string](Get-ThresholdJsonProperty $CandidateSnapshot "member" "")
    $basis = @(
        "candidateId=$candidateId",
        "candidateClass=$candidateClass",
        "file=$file",
        "member=$member"
    )
    return Get-ThresholdStringSha256Lower -Text ([string]::Join("`n", $basis))
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
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json",
        [object] $CandidateSnapshot = $null
    )

    $candidate = if ($null -ne $CandidateSnapshot) { $CandidateSnapshot } else { Get-ThresholdCandidateFromPocket -CandidatePocketPath $CandidatePocketPath -CandidateId $CandidateId }
    $executionCandidateSnapshot = New-ThresholdCandidateSnapshot -Candidate $candidate
    $executionCandidateDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $executionCandidateSnapshot
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
        "commitHash=$CommitHash",
        "executionCandidateDigest=$executionCandidateDigest"
    )

    return [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-class-provenance.v0.1"
        discoveryObservation = if ($candidate) { "receipt-bound-execution-pocket" } else { "missing" }
        discoveryRuleId = $discoveryRuleId
        discoveryCandidateId = $CandidateId
        executionCandidateSnapshot = $executionCandidateSnapshot
        executionCandidateDigest = $executionCandidateDigest
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

function Assert-ThresholdProvenanceFieldMatches {
    param([object] $Observed, [object] $Expected, [string] $Field, [string] $ReceiptPath)

    $observedValue = Get-ThresholdJsonProperty $Observed $Field $null
    $expectedValue = Get-ThresholdJsonProperty $Expected $Field $null
    if ([string]$observedValue -ne [string]$expectedValue) {
        throw "candidateClassProvenance recompute mismatch field=$Field receipt=$ReceiptPath observed=$observedValue expected=$expectedValue"
    }
}

function Assert-ThresholdCandidateClassProvenance {
    param(
        [pscustomobject] $Receipt,
        [string] $ReceiptPath = "",
        [switch] $RequirePresent,
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json"
    )

    $provenance = Get-ThresholdJsonProperty $Receipt "candidateClassProvenance" $null
    if ($null -eq $provenance) {
        if ($RequirePresent.IsPresent) {
            throw "candidateClassProvenance missing receipt=$ReceiptPath"
        }
        return
    }
    $candidateId = Get-ThresholdJsonProperty $Receipt "candidateId" $null
    $batchId = Get-ThresholdJsonProperty $Receipt "batchId" $null
    if (-not [string]::IsNullOrWhiteSpace([string]$batchId) -and [string]::IsNullOrWhiteSpace([string]$candidateId)) {
        throw "candidateClassProvenance batch receipt cannot establish positive learning without candidateId receipt=$ReceiptPath batchId=$batchId"
    }
    if ((Get-ThresholdJsonProperty $provenance "candidateClassProvenanceMatched" $false) -ne $true) {
        throw "candidateClassProvenanceMatched=false receipt=$ReceiptPath observedDiffClass=$($provenance.independentlyObservedDiffClass) receiptCandidateClass=$($provenance.receiptCandidateClass)"
    }
    foreach ($field in @("productMutationAdmission", "receiptAdmission", "kgMaterialization", "trainerMaterialization", "publicationAdmission", "readyAdmission", "mergeAdmission", "promotionEvidenceContribution")) {
        if ((Get-ThresholdJsonProperty $provenance $field $false) -ne $true) {
            throw "candidateClassProvenance admission field failed: $field receipt=$ReceiptPath"
        }
    }

    $candidateId = Get-ThresholdJsonProperty $Receipt "candidateId" $null
    $baseHead = Get-ThresholdJsonProperty $Receipt "baseHead" $null
    $commitHash = Get-ThresholdJsonProperty $Receipt "commitHash" $null
    if ([string]::IsNullOrWhiteSpace([string]$commitHash)) {
        $commitHash = Get-ThresholdJsonProperty $Receipt "sourceCommit" $null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$candidateId) -and
        -not [string]::IsNullOrWhiteSpace([string]$baseHead) -and
        -not [string]::IsNullOrWhiteSpace([string]$commitHash)) {
        $parentHead = (& git rev-parse "$commitHash^1" 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$parentHead)) {
            throw "candidateClassProvenance commit parent unavailable receipt=$ReceiptPath commitHash=$commitHash"
        }
        if ([string]$baseHead -ne [string]($parentHead.Trim())) {
            throw "candidateClassProvenance baseHead mismatch receipt=$ReceiptPath baseHead=$baseHead parentHead=$([string]($parentHead.Trim()))"
        }

        $embeddedSnapshot = Get-ThresholdJsonProperty $provenance "executionCandidateSnapshot" $null
        $independentCandidate = Get-ThresholdCandidateFromPocket -CandidatePocketPath $CandidatePocketPath -CandidateId ([string]$candidateId)
        $candidateForRecompute = $independentCandidate
        if ($null -ne $embeddedSnapshot) {
            $embeddedDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $embeddedSnapshot
            if ([string]$embeddedDigest -ne [string](Get-ThresholdJsonProperty $provenance "executionCandidateDigest" "")) {
                throw "candidateClassProvenance execution snapshot digest mismatch receipt=$ReceiptPath embeddedDigest=$embeddedDigest provenanceDigest=$($provenance.executionCandidateDigest)"
            }
            if ([string](Get-ThresholdJsonProperty $embeddedSnapshot "candidateId" "") -ne [string]$candidateId) {
                throw "candidateClassProvenance execution snapshot candidateId mismatch receipt=$ReceiptPath candidateId=$candidateId embeddedCandidateId=$($embeddedSnapshot.candidateId)"
            }
            if ([string](Get-ThresholdJsonProperty $embeddedSnapshot "candidateClass" "") -ne [string](Get-ThresholdJsonProperty $provenance "discoveredCandidateClass" "")) {
                throw "candidateClassProvenance execution snapshot candidateClass mismatch receipt=$ReceiptPath embeddedCandidateClass=$($embeddedSnapshot.candidateClass) discoveredCandidateClass=$($provenance.discoveredCandidateClass)"
            }
            if ($null -ne $independentCandidate) {
                $independentDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot (New-ThresholdCandidateSnapshot -Candidate $independentCandidate)
                if ($embeddedDigest -ne $independentDigest) {
                    throw "candidateClassProvenance execution snapshot mismatch receipt=$ReceiptPath embeddedDigest=$embeddedDigest independentDigest=$independentDigest"
                }
            }
            else {
                $candidateForRecompute = $embeddedSnapshot
            }
        }

        $expected = New-ThresholdCandidateClassProvenance `
            -CandidateId ([string]$candidateId) `
            -GrantedCandidateClass ([string](Get-ThresholdJsonProperty $provenance "grantedCandidateClass" "")) `
            -ExecutorCandidateClass ([string](Get-ThresholdJsonProperty $provenance "executorCandidateClass" "")) `
            -ReceiptCandidateClass ([string](Get-ThresholdJsonProperty $Receipt "candidateClass" (Get-ThresholdJsonProperty $provenance "receiptCandidateClass" ""))) `
            -LearningProjectionClass ([string](Get-ThresholdJsonProperty $provenance "learningProjectionClass" "")) `
            -BaseHead ([string]$baseHead) `
            -CommitHash ([string]$commitHash) `
            -CandidatePocketPath $CandidatePocketPath `
            -CandidateSnapshot $candidateForRecompute

        foreach ($field in @(
            "discoveryObservation",
            "discoveryRuleId",
            "discoveryCandidateId",
            "executionCandidateDigest",
            "discoveredCandidateClass",
            "grantedCandidateClass",
            "executorCandidateClass",
            "independentlyObservedDiffClass",
            "receiptCandidateClass",
            "learningProjectionClass",
            "candidateClassProvenanceMatched",
            "productMutationAdmission",
            "receiptAdmission",
            "kgMaterialization",
            "trainerMaterialization",
            "publicationAdmission",
            "readyAdmission",
            "mergeAdmission",
            "promotionEvidenceContribution",
            "provenanceDigest"
        )) {
            Assert-ThresholdProvenanceFieldMatches -Observed $provenance -Expected $expected -Field $field -ReceiptPath $ReceiptPath
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$candidateId)) {
        throw "candidateClassProvenance cannot be recomputed without candidateId, baseHead, and commitHash/sourceCommit receipt=$ReceiptPath"
    }
}

function Test-ThresholdCandidateClassProvenancePositiveLearningEligible {
    param([pscustomobject] $Receipt)

    $provenance = Get-ThresholdJsonProperty $Receipt "candidateClassProvenance" $null
    if ($null -eq $provenance) {
        return $false
    }
    $candidateId = Get-ThresholdJsonProperty $Receipt "candidateId" $null
    $batchId = Get-ThresholdJsonProperty $Receipt "batchId" $null
    if (-not [string]::IsNullOrWhiteSpace([string]$batchId) -and [string]::IsNullOrWhiteSpace([string]$candidateId)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$candidateId)) {
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
