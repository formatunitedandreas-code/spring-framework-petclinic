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

function Remove-ThresholdJavaLineCommentOutsideLiteral {
    param([string] $Line)

    $insideString = $false
    $insideChar = $false
    $escaped = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        $next = if ($i + 1 -lt $Line.Length) { $Line[$i + 1] } else { [char]0 }

        if ($escaped) {
            $escaped = $false
            continue
        }
        if (($insideString -or $insideChar) -and $ch -eq '\') {
            $escaped = $true
            continue
        }
        if (-not $insideChar -and $ch -eq '"') {
            $insideString = -not $insideString
            continue
        }
        if (-not $insideString -and $ch -eq "'") {
            $insideChar = -not $insideChar
            continue
        }
        if (-not $insideString -and -not $insideChar -and $ch -eq "/" -and $next -eq "/") {
            return $Line.Substring(0, $i)
        }
    }
    return $Line
}

function Test-ThresholdJavaCharacterIsEscaped {
    param([string] $Line, [int] $Index)

    $backslashCount = 0
    for ($i = $Index - 1; $i -ge 0; $i--) {
        if ($Line[$i] -ne '\') {
            break
        }
        $backslashCount++
    }
    return (($backslashCount % 2) -eq 1)
}

function Get-ThresholdJavaTextBlockDelimiterCount {
    param([string] $Line)

    $count = 0
    for ($i = 0; $i -le ($Line.Length - 3); $i++) {
        if ($Line[$i] -eq '"' -and
            $Line[$i + 1] -eq '"' -and
            $Line[$i + 2] -eq '"' -and
            -not (Test-ThresholdJavaCharacterIsEscaped -Line $Line -Index $i)) {
            $count++
            $i += 2
        }
    }
    return $count
}

function Get-ThresholdJavaTextBlockLineState {
    param([string[]] $Lines)

    $states = @{}
    $insideTextBlock = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $lineNumber = $i + 1
        $line = [string]$Lines[$i]
        if ($insideTextBlock) {
            $states[$lineNumber] = $true
        }
        $lexicalLine = $line
        if (-not $insideTextBlock) {
            $lexicalLine = Remove-ThresholdJavaLineCommentOutsideLiteral -Line $line
        }
        $delimiterCount = Get-ThresholdJavaTextBlockDelimiterCount -Line $lexicalLine
        if (($delimiterCount % 2) -eq 1) {
            $insideTextBlock = -not $insideTextBlock
            if (-not $insideTextBlock) {
                $states[$lineNumber] = $true
            }
        }
    }
    return $states
}

function Test-ThresholdJavaLineIsInsideTextBlock {
    param([string[]] $Lines, [int] $LineNumber)
    if ($LineNumber -lt 1 -or $LineNumber -gt $Lines.Count) {
        return $false
    }
    $states = Get-ThresholdJavaTextBlockLineState -Lines $Lines
    return $states.ContainsKey($LineNumber)
}

function Get-ThresholdDiffRemovedLineNumbers {
    param([string[]] $DiffLines)

    $lineNumbers = New-Object System.Collections.Generic.List[int]
    $oldLine = 0
    foreach ($line in $DiffLines) {
        $hunk = [regex]::Match([string]$line, '^@@ -(?<oldStart>\d+)(,(?<oldCount>\d+))? \+(?<newStart>\d+)(,(?<newCount>\d+))? @@')
        if ($hunk.Success) {
            $oldLine = [int]$hunk.Groups["oldStart"].Value
            continue
        }
        if ($line -match '^(diff --git |index |\-\-\- |\+\+\+ )') {
            continue
        }
        if ($line.StartsWith("-")) {
            $lineNumbers.Add($oldLine)
            $oldLine++
            continue
        }
        if ($line.StartsWith("+")) {
            continue
        }
        if ($line.StartsWith(" ") -or $line.Length -eq 0) {
            $oldLine++
        }
    }
    return $lineNumbers.ToArray()
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
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+ "[^"\\]+";\s*$' })
    $addedStart = @($contentLines | Where-Object { $_ -match '^\+\s*private static final String [A-Z0-9_]+ = "[^"\\]+"\s*$' })
    $addedContinuation = @($contentLines | Where-Object { $_ -match '^\+\s*\+ "[^"\\]+";\s*$' })
    $nonStringDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and
        $_ -notmatch '^[+-]\s*private static final String [A-Z0-9_]+ = "[^"\\]+"(?: \+ "[^"\\]+")?;?\s*$' -and
        $_ -notmatch '^\+\s*\+ "[^"\\]+";\s*$'
    })
    if ($removed.Count -ne 1 -or $addedStart.Count -ne 1 -or $addedContinuation.Count -ne 1 -or $nonStringDelta.Count -ne 0) {
        return $false
    }
    $removedMatch = [regex]::Match($removed[0], '^-\s*private static final String (?<name>[A-Z0-9_]+) = "(?<first>[^"\\]+)" \+ "(?<second>[^"\\]+)";\s*$')
    $addedStartMatch = [regex]::Match($addedStart[0], '^\+\s*private static final String (?<name>[A-Z0-9_]+) = "(?<first>[^"\\]+)"\s*$')
    $addedContinuationMatch = [regex]::Match($addedContinuation[0], '^\+\s*\+ "(?<second>[^"\\]+)";\s*$')
    return $removedMatch.Groups["name"].Value -eq $addedStartMatch.Groups["name"].Value -and
        $removedMatch.Groups["first"].Value -eq $addedStartMatch.Groups["first"].Value -and
        $removedMatch.Groups["second"].Value -eq $addedContinuationMatch.Groups["second"].Value
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
    param(
        [string[]] $DiffLines,
        [string] $BaseHead = "",
        [string] $ProductPath = ""
    )

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match "^-\t+\S" })
    $added = @($contentLines | Where-Object { $_ -match '^\+ {4,}\S' })
    if ($removed.Count -eq 0 -or $removed.Count -ne $added.Count) { return $false }
    $nonIndentDelta = @($contentLines | Where-Object {
        $_ -match '^[+-]' -and $_ -notmatch "^-\t+\S" -and $_ -notmatch '^\+ {4,}\S'
    })
    if ($nonIndentDelta.Count -ne 0) { return $false }
    for ($i = 0; $i -lt $removed.Count; $i++) {
        $normalizedRemoved = [regex]::Replace($removed[$i].Substring(1), "^\t+", { param($m) return " " * (4 * $m.Value.Length) })
        $normalizedAdded = $added[$i].Substring(1)
        if ($normalizedRemoved -ne $normalizedAdded) { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseHead) -and -not [string]::IsNullOrWhiteSpace($ProductPath)) {
        $baseLines = @(& git show "$BaseHead`:$ProductPath" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $baseLines.Count -eq 0) {
            return $false
        }
        $removedLineNumbers = @(Get-ThresholdDiffRemovedLineNumbers -DiffLines $DiffLines)
        foreach ($lineNumber in $removedLineNumbers) {
            if (Test-ThresholdJavaLineIsInsideTextBlock -Lines $baseLines -LineNumber $lineNumber) {
                return $false
            }
        }
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

function Get-ThresholdIndependentlyObservedDiffProductPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash
    )

    $paths = @(& git diff --name-only "$BaseHead..$CommitHash" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $productPaths = @($paths | Where-Object { $_ -like "src/main/java/*.java" -or $_ -like "src/main/java/**/*.java" })
    if ($productPaths.Count -ne 1 -or $paths.Count -ne 1) {
        return ""
    }
    return ConvertTo-ThresholdRepoPath -Path ([string]$productPaths[0])
}

function Test-ThresholdObservedDiffMemberMatchesCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash,
        [Parameter(Mandatory = $true)]
        [string] $ProductPath,
        [string] $CandidateMember
    )

    if ([string]::IsNullOrWhiteSpace($CandidateMember) -or $CandidateMember -notmatch '^line-(?<line>\d+)$') {
        return $true
    }
    $candidateLine = [int]$Matches['line']
    $hunkLines = @(& git diff --unified=0 "$BaseHead..$CommitHash" -- $ProductPath | Where-Object { $_ -match '^@@ ' })
    if ($hunkLines.Count -eq 0) { return $false }
    foreach ($hunkLine in $hunkLines) {
        $match = [regex]::Match($hunkLine, '^@@ -(?<oldStart>\d+)(,(?<oldCount>\d+))? \+(?<newStart>\d+)(,(?<newCount>\d+))? @@')
        if (-not $match.Success) { continue }
        $oldStart = [int]$match.Groups['oldStart'].Value
        $oldCount = if ($match.Groups['oldCount'].Success) { [int]$match.Groups['oldCount'].Value } else { 1 }
        $newStart = [int]$match.Groups['newStart'].Value
        $newCount = if ($match.Groups['newCount'].Success) { [int]$match.Groups['newCount'].Value } else { 1 }
        if ($oldCount -eq 0 -and $newCount -gt 0) {
            $newEnd = $newStart + $newCount - 1
            if ($candidateLine -ge $newStart -and $candidateLine -le $newEnd) {
                return $true
            }
            continue
        }
        $oldEnd = if ($oldCount -le 0) { $oldStart } else { $oldStart + $oldCount - 1 }
        if ($candidateLine -ge $oldStart -and $candidateLine -le $oldEnd) {
            return $true
        }
    }
    return $false
}

function Get-ThresholdIndependentlyObservedDiffClass {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash
    )

    $productPath = Get-ThresholdIndependentlyObservedDiffProductPath -BaseHead $BaseHead -CommitHash $CommitHash
    if ([string]::IsNullOrWhiteSpace($productPath)) {
        return "compound_or_governance_diff"
    }

    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $productPath)
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
    if (Test-ThresholdLeadingTabIndentationDiff -DiffLines $diffLines -BaseHead $BaseHead -ProductPath $productPath) {
        return "leading_tab_indentation_cleanup"
    }
    return "unknown"
}

function Get-ThresholdCandidateExecutionParameters {
    param([object] $Candidate)
    $explicitParameters = Get-ThresholdJsonProperty $Candidate "executionParameters" $null
    if ($null -ne $explicitParameters) {
        return $explicitParameters
    }
    $candidateClass = [string](Get-ThresholdJsonProperty $Candidate "candidateClass" "")
    $parameters = [ordered]@{}
    switch ($candidateClass) {
        "leading_tab_indentation_cleanup" {
            $lineCount = Get-ThresholdJsonProperty $Candidate "lineCount" $null
            if ($null -ne $lineCount -and -not [string]::IsNullOrWhiteSpace([string]$lineCount)) {
                $parameters.lineCount = [int]$lineCount
            }
        }
        "method_spacing_normalization" {
            $spacingAction = [string](Get-ThresholdJsonProperty $Candidate "spacingAction" "")
            if (-not [string]::IsNullOrWhiteSpace($spacingAction)) {
                $parameters.spacingAction = $spacingAction
            }
        }
    }
    return $parameters
}

function Get-ThresholdCanonicalExecutionParametersText {
    param([object] $ExecutionParameters)
    if ($null -eq $ExecutionParameters) { return "" }
    $pairs = New-Object System.Collections.Generic.List[string]
    if ($ExecutionParameters -is [System.Collections.IDictionary]) {
        foreach ($key in @($ExecutionParameters.Keys | Sort-Object)) {
            $pairs.Add("$key=$($ExecutionParameters[$key])")
        }
    }
    else {
        foreach ($property in @($ExecutionParameters.PSObject.Properties | Sort-Object Name)) {
            $pairs.Add("$($property.Name)=$($property.Value)")
        }
    }
    return [string]::Join("`n", $pairs.ToArray())
}

function Test-ThresholdExecutionParametersEqual {
    param([object] $Observed, [object] $Expected)
    return (Get-ThresholdCanonicalExecutionParametersText -ExecutionParameters $Observed) -eq
        (Get-ThresholdCanonicalExecutionParametersText -ExecutionParameters $Expected)
}

function Get-ThresholdMethodSpacingObservedAction {
    param([string[]] $DiffLines)
    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $deltaLines = @($contentLines | Where-Object { $_ -match '^[+-]' })
    if (@($deltaLines | Where-Object { $_ -eq "+" }).Count -eq 1 -and @($deltaLines | Where-Object { $_ -eq "-" }).Count -eq 0) {
        return "insert_blank_line"
    }
    if (@($deltaLines | Where-Object { $_ -eq "-" }).Count -eq 1 -and @($deltaLines | Where-Object { $_ -eq "+" }).Count -eq 0) {
        return "collapse_extra_blank_line"
    }
    return ""
}

function Get-ThresholdLeadingTabObservedLineCount {
    param([string[]] $DiffLines)
    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    return @($contentLines | Where-Object { $_ -match "^-\t+\S" }).Count
}

function Test-ThresholdLeadingTabObservedLinesMatchCandidateBlock {
    param(
        [string[]] $DiffLines,
        [string] $CandidateMember,
        [int] $LineCount
    )

    if ($LineCount -lt 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($CandidateMember) -or $CandidateMember -notmatch '^line-(?<line>\d+)$') {
        return $false
    }
    $candidateStartLine = [int]$Matches['line']
    $removedLineNumbers = @(Get-ThresholdDiffRemovedLineNumbers -DiffLines $DiffLines | Sort-Object)
    if ($removedLineNumbers.Count -ne $LineCount) { return $false }
    for ($i = 0; $i -lt $LineCount; $i++) {
        if ([int]$removedLineNumbers[$i] -ne ($candidateStartLine + $i)) {
            return $false
        }
    }
    return $true
}

function Test-ThresholdCandidateExecutionParametersMatchObservedDiff {
    param(
        [string] $CandidateClass,
        [object] $ExecutionParameters,
        [string] $BaseHead,
        [string] $CommitHash,
        [string] $ProductPath,
        [string] $CandidateMember = ""
    )
    if ([string]::IsNullOrWhiteSpace($ProductPath)) {
        return $false
    }
    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $ProductPath)
    switch ($CandidateClass) {
        "leading_tab_indentation_cleanup" {
            $expectedLineCount = Get-ThresholdJsonProperty $ExecutionParameters "lineCount" $null
            if ($null -eq $expectedLineCount -or [int]$expectedLineCount -lt 1) { return $false }
            return [int]$expectedLineCount -eq (Get-ThresholdLeadingTabObservedLineCount -DiffLines $diffLines) -and
                (Test-ThresholdLeadingTabObservedLinesMatchCandidateBlock -DiffLines $diffLines -CandidateMember $CandidateMember -LineCount ([int]$expectedLineCount))
        }
        "method_spacing_normalization" {
            $expectedSpacingAction = [string](Get-ThresholdJsonProperty $ExecutionParameters "spacingAction" "")
            if ([string]::IsNullOrWhiteSpace($expectedSpacingAction)) { return $false }
            return $expectedSpacingAction -eq (Get-ThresholdMethodSpacingObservedAction -DiffLines $diffLines)
        }
    }
    return $true
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
        executionParameters = Get-ThresholdCandidateExecutionParameters -Candidate $Candidate
    }
}

function Get-ThresholdCandidateSnapshotDigest {
    param([object] $CandidateSnapshot)
    if ($null -eq $CandidateSnapshot) { return "" }
    $candidateId = [string](Get-ThresholdJsonProperty $CandidateSnapshot "candidateId" "")
    $candidateClass = [string](Get-ThresholdJsonProperty $CandidateSnapshot "candidateClass" "")
    $file = [string](Get-ThresholdJsonProperty $CandidateSnapshot "file" "")
    $member = [string](Get-ThresholdJsonProperty $CandidateSnapshot "member" "")
    $executionParametersText = Get-ThresholdCanonicalExecutionParametersText -ExecutionParameters (Get-ThresholdJsonProperty $CandidateSnapshot "executionParameters" ([ordered]@{}))
    $basis = @(
        "candidateId=$candidateId",
        "candidateClass=$candidateClass",
        "file=$file",
        "member=$member",
        "executionParameters=$executionParametersText"
    )
    return Get-ThresholdStringSha256Lower -Text ([string]::Join("`n", $basis))
}

function Get-ThresholdCandidatePocketDigest {
    param([string] $CandidatePocketPath)
    if ([string]::IsNullOrWhiteSpace($CandidatePocketPath) -or -not (Test-Path $CandidatePocketPath)) {
        return ""
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $CandidatePocketPath).Hash.ToLowerInvariant()
}

function Get-ThresholdDiscoveryRuleDigest {
    param([string] $DiscoveryRuleId, [string] $CandidateClass)
    if ([string]::IsNullOrWhiteSpace($DiscoveryRuleId) -or [string]::IsNullOrWhiteSpace($CandidateClass)) {
        return ""
    }
    return Get-ThresholdStringSha256Lower -Text "discoveryRuleId=$DiscoveryRuleId`ncandidateClass=$CandidateClass"
}

function Get-ThresholdCandidateDiscoveryEvidencePath {
    param(
        [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence",
        [string] $CandidateId,
        [string] $BaseHead
    )

    $safeCandidateId = ([string]$CandidateId) -replace "[^A-Za-z0-9_.-]", "-"
    $safeBaseHead = ([string]$BaseHead) -replace "[^A-Za-z0-9_.-]", "-"
    if ($safeBaseHead.Length -gt 12) {
        $safeBaseHead = $safeBaseHead.Substring(0, 12)
    }
    return Join-Path $DiscoveryEvidenceRoot "$safeCandidateId-$safeBaseHead.discovery-evidence.json"
}

function Write-ThresholdCandidateDiscoveryEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object] $DiscoveryEvidence,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $parent = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $DiscoveryEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path
}

function Get-ThresholdCandidateDiscoveryEvidenceFromPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-ThresholdCandidateDiscoveryEvidenceFromRevision {
    param([string] $Revision, [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Revision) -or [string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $repoPath = ConvertTo-ThresholdRepoPath -Path $Path
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git cat-file -e "$Revision`:$repoPath" 2>$null
    $exists = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previousErrorActionPreference
    if (-not $exists) {
        return $null
    }
    $text = (& git show "$Revision`:$repoPath" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Get-ThresholdLastCommitTouchingPath {
    param([string] $Revision, [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Revision) -or [string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $repoPath = ConvertTo-ThresholdRepoPath -Path $Path
    $commit = (& git log -n 1 --format=%H $Revision -- $repoPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$commit)) {
        return ""
    }
    return [string]($commit.Trim())
}

function Test-ThresholdCommitIsAncestor {
    param([string] $Ancestor, [string] $Descendant)
    if ([string]::IsNullOrWhiteSpace($Ancestor) -or [string]::IsNullOrWhiteSpace($Descendant)) {
        return $false
    }
    & git merge-base --is-ancestor $Ancestor $Descendant 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-ThresholdPathChangedInRange {
    param([string] $BaseHead, [string] $CommitHash, [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    $repoPath = ConvertTo-ThresholdRepoPath -Path $Path
    $changedPaths = @(& git diff --name-only "$BaseHead..$CommitHash" -- $repoPath 2>$null)
    return @($changedPaths | Where-Object { (ConvertTo-ThresholdRepoPath -Path $_) -eq $repoPath }).Count -gt 0
}

function Get-ThresholdCandidateDiscoveryEvidenceDigest {
    param([object] $DiscoveryEvidence)
    if ($null -eq $DiscoveryEvidence) { return "" }
    $repositoryId = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "repositoryId" "")
    $baseHead = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "baseHead" "")
    $discoveryRunId = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "discoveryRunId" "")
    $discoveryRuleId = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "discoveryRuleId" "")
    $discoveryRuleDigest = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "discoveryRuleDigest" "")
    $candidateId = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateId" "")
    $candidateClass = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateClass" "")
    $candidatePath = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidatePath" "")
    $candidateMember = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateMember" "")
    $candidateHunkFingerprint = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateHunkFingerprint" "")
    $candidateSnapshotDigest = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateSnapshotDigest" "")
    $executionParametersDigest = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "executionParametersDigest" "")
    $candidatePocketDigest = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidatePocketDigest" "")
    $basis = @(
        "repositoryId=$repositoryId",
        "baseHead=$baseHead",
        "discoveryRunId=$discoveryRunId",
        "discoveryRuleId=$discoveryRuleId",
        "discoveryRuleDigest=$discoveryRuleDigest",
        "candidateId=$candidateId",
        "candidateClass=$candidateClass",
        "candidatePath=$candidatePath",
        "candidateMember=$candidateMember",
        "candidateHunkFingerprint=$candidateHunkFingerprint",
        "candidateSnapshotDigest=$candidateSnapshotDigest",
        "executionParametersDigest=$executionParametersDigest",
        "candidatePocketDigest=$candidatePocketDigest"
    )
    return Get-ThresholdStringSha256Lower -Text ([string]::Join("`n", $basis))
}

function New-ThresholdCandidateFromDiscoveryEvidence {
    param([object] $DiscoveryEvidence)
    if ($null -eq $DiscoveryEvidence) { return $null }
    return [ordered]@{
        candidateId = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateId" "")
        candidateClass = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateClass" "")
        file = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidatePath" "")
        member = [string](Get-ThresholdJsonProperty $DiscoveryEvidence "candidateMember" "")
        executionParameters = Get-ThresholdJsonProperty $DiscoveryEvidence "executionParameters" ([ordered]@{})
    }
}

function New-ThresholdCandidateDiscoveryEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CandidateId,
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json",
        [object] $Candidate = $null
    )

    $candidate = if ($null -ne $Candidate) { $Candidate } else { Get-ThresholdCandidateFromPocket -CandidatePocketPath $CandidatePocketPath -CandidateId $CandidateId }
    if ($null -eq $candidate) { return $null }

    $candidateSnapshot = New-ThresholdCandidateSnapshot -Candidate $candidate
    $candidateSnapshotDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $candidateSnapshot
    $candidateClass = [string](Get-ThresholdJsonProperty $candidateSnapshot "candidateClass" "")
    $candidatePath = ConvertTo-ThresholdRepoPath -Path ([string](Get-ThresholdJsonProperty $candidateSnapshot "file" ""))
    $candidateMember = [string](Get-ThresholdJsonProperty $candidateSnapshot "member" "")
    $executionParameters = Get-ThresholdJsonProperty $candidateSnapshot "executionParameters" ([ordered]@{})
    $executionParametersDigest = Get-ThresholdStringSha256Lower -Text (Get-ThresholdCanonicalExecutionParametersText -ExecutionParameters $executionParameters)
    $discoveryRuleId = "static-heuristic-scan:$candidateClass"
    $candidatePocketDigest = Get-ThresholdCandidatePocketDigest -CandidatePocketPath $CandidatePocketPath
    $candidateHunkFingerprint = Get-ThresholdStringSha256Lower -Text "candidatePath=$candidatePath`ncandidateMember=$candidateMember"
    $basis = @(
        "repositoryId=formatunitedandreas-code/spring-framework-petclinic",
        "baseHead=$BaseHead",
        "discoveryRunId=pocket:$candidatePocketDigest",
        "discoveryRuleId=$discoveryRuleId",
        "discoveryRuleDigest=$(Get-ThresholdDiscoveryRuleDigest -DiscoveryRuleId $discoveryRuleId -CandidateClass $candidateClass)",
        "candidateId=$CandidateId",
        "candidateClass=$candidateClass",
        "candidatePath=$candidatePath",
        "candidateMember=$candidateMember",
        "candidateHunkFingerprint=$candidateHunkFingerprint",
        "candidateSnapshotDigest=$candidateSnapshotDigest",
        "executionParametersDigest=$executionParametersDigest",
        "candidatePocketDigest=$candidatePocketDigest"
    )

    $discoveryEvidenceDigest = Get-ThresholdStringSha256Lower -Text ([string]::Join("`n", $basis))
    return [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-discovery-evidence.v0.1"
        repositoryId = "formatunitedandreas-code/spring-framework-petclinic"
        baseHead = $BaseHead
        discoveryRunId = "pocket:$candidatePocketDigest"
        discoveryRuleId = $discoveryRuleId
        discoveryRuleDigest = Get-ThresholdDiscoveryRuleDigest -DiscoveryRuleId $discoveryRuleId -CandidateClass $candidateClass
        candidateId = $CandidateId
        candidateClass = $candidateClass
        candidatePath = $candidatePath
        candidateMember = $candidateMember
        candidateHunkFingerprint = $candidateHunkFingerprint
        candidateSnapshotDigest = $candidateSnapshotDigest
        executionParameters = $executionParameters
        executionParametersDigest = $executionParametersDigest
        candidatePocketDigest = $candidatePocketDigest
        discoveryEvidenceDigest = $discoveryEvidenceDigest
    }
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
        [string] $PrBaseHead = "",
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json",
        [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence",
        [string] $DiscoveryEvidencePath = "",
        [switch] $MaterializeDiscoveryEvidence,
        [object] $CandidateSnapshot = $null
    )

    $discoveryEvidenceFromPath = if (-not [string]::IsNullOrWhiteSpace($DiscoveryEvidencePath)) { Get-ThresholdCandidateDiscoveryEvidenceFromPath -Path $DiscoveryEvidencePath } else { $null }
    $candidate = if ($null -ne $CandidateSnapshot) {
        $CandidateSnapshot
    }
    elseif ($null -ne $discoveryEvidenceFromPath) {
        New-ThresholdCandidateFromDiscoveryEvidence -DiscoveryEvidence $discoveryEvidenceFromPath
    }
    else {
        Get-ThresholdCandidateFromPocket -CandidatePocketPath $CandidatePocketPath -CandidateId $CandidateId
    }
    $discoveryEvidence = if ($null -ne $CandidateSnapshot) {
        $null
    }
    elseif ($null -ne $discoveryEvidenceFromPath) {
        $discoveryEvidenceFromPath
    }
    else {
        New-ThresholdCandidateDiscoveryEvidence -BaseHead $BaseHead -CandidateId $CandidateId -CandidatePocketPath $CandidatePocketPath -Candidate $candidate
    }
    if ($null -ne $discoveryEvidence -and [string]::IsNullOrWhiteSpace($DiscoveryEvidencePath)) {
        $DiscoveryEvidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot -CandidateId $CandidateId -BaseHead $BaseHead
    }
    if ($MaterializeDiscoveryEvidence.IsPresent -and $null -ne $discoveryEvidence) {
        Write-ThresholdCandidateDiscoveryEvidence -DiscoveryEvidence $discoveryEvidence -Path $DiscoveryEvidencePath
    }
    $prBaseHeadPresent = -not [string]::IsNullOrWhiteSpace($PrBaseHead)
    $effectivePrBaseHead = if ($prBaseHeadPresent) { [string]$PrBaseHead } else { "" }
    $prBaseHeadMatched = $prBaseHeadPresent
    $discoveryEvidenceDigest = if ($null -ne $discoveryEvidence) { [string]$discoveryEvidence.discoveryEvidenceDigest } else { "" }
    $discoveryEvidenceCreatedByCurrentProductPr = Test-ThresholdPathChangedInRange -BaseHead $BaseHead -CommitHash $CommitHash -Path $DiscoveryEvidencePath
    $discoveryEvidenceChangedInsideProductPr = if ($prBaseHeadPresent) { Test-ThresholdPathChangedInRange -BaseHead $effectivePrBaseHead -CommitHash $CommitHash -Path $DiscoveryEvidencePath } else { $false }
    $baseDiscoveryEvidence = Get-ThresholdCandidateDiscoveryEvidenceFromRevision -Revision $effectivePrBaseHead -Path $DiscoveryEvidencePath
    $baseDiscoveryEvidenceDigest = if ($null -ne $baseDiscoveryEvidence) { Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $baseDiscoveryEvidence } else { "" }
    $discoveryEvidencePresentInBaseHead = $null -ne $baseDiscoveryEvidence
    $discoveryEvidenceBaseDigestMatched = $discoveryEvidencePresentInBaseHead -and [string]$baseDiscoveryEvidenceDigest -eq [string]$discoveryEvidenceDigest
    $discoveryEvidenceCommit = Get-ThresholdLastCommitTouchingPath -Revision $effectivePrBaseHead -Path $DiscoveryEvidencePath
    $discoveryEvidenceCommitIsAncestorOfBaseHead = Test-ThresholdCommitIsAncestor -Ancestor $discoveryEvidenceCommit -Descendant $effectivePrBaseHead
    $discoveryEvidenceSourceBaseHead = if ($null -ne $discoveryEvidence) { [string](Get-ThresholdJsonProperty $discoveryEvidence "baseHead" "") } else { "" }
    $discoveryEvidenceSourceBaseHeadIsAncestorOfBaseHead = Test-ThresholdCommitIsAncestor -Ancestor $discoveryEvidenceSourceBaseHead -Descendant $effectivePrBaseHead
    $externalDiscoverySignatureVerified = $false
    $discoveryEvidenceTrustRootVerified = (
        $prBaseHeadPresent -and
        $prBaseHeadMatched -and
        -not $discoveryEvidenceChangedInsideProductPr -and
        $discoveryEvidencePresentInBaseHead -and
        $discoveryEvidenceBaseDigestMatched -and
        $discoveryEvidenceCommitIsAncestorOfBaseHead -and
        $discoveryEvidenceSourceBaseHeadIsAncestorOfBaseHead
    ) -or $externalDiscoverySignatureVerified
    $immutableDiscoveryEvidencePresent = $null -ne $discoveryEvidence -and
        -not [string]::IsNullOrWhiteSpace($discoveryEvidenceDigest) -and
        -not [string]::IsNullOrWhiteSpace($DiscoveryEvidencePath) -and
        (Test-Path $DiscoveryEvidencePath) -and
        [string](Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $discoveryEvidence) -eq [string]$discoveryEvidenceDigest -and
        $discoveryEvidenceTrustRootVerified
    $executionCandidateSnapshot = New-ThresholdCandidateSnapshot -Candidate $candidate
    $executionCandidateDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $executionCandidateSnapshot
    $discoveryRuleId = $null
    $discoveredCandidateClass = $null
    if ($candidate) {
        $discoveredCandidateClass = [string]$candidate.candidateClass
        $discoveryRuleId = "static-heuristic-scan:$discoveredCandidateClass"
    }
    $observedDiffClass = Get-ThresholdIndependentlyObservedDiffClass -BaseHead $BaseHead -CommitHash $CommitHash
    $observedDiffPath = Get-ThresholdIndependentlyObservedDiffProductPath -BaseHead $BaseHead -CommitHash $CommitHash
    $candidateFile = ConvertTo-ThresholdRepoPath -Path ([string](Get-ThresholdJsonProperty $executionCandidateSnapshot "file" ""))
    $candidateMember = [string](Get-ThresholdJsonProperty $executionCandidateSnapshot "member" "")
    $executionParameters = Get-ThresholdJsonProperty $executionCandidateSnapshot "executionParameters" ([ordered]@{})
    $candidatePathMatched = -not [string]::IsNullOrWhiteSpace($candidateFile) -and [string]$candidateFile -eq [string]$observedDiffPath
    $candidateMemberMatched = $candidatePathMatched -and (Test-ThresholdObservedDiffMemberMatchesCandidate -BaseHead $BaseHead -CommitHash $CommitHash -ProductPath $observedDiffPath -CandidateMember $candidateMember)
    $candidateExecutionParametersMatched = $candidatePathMatched -and (Test-ThresholdCandidateExecutionParametersMatchObservedDiff -CandidateClass ([string]$discoveredCandidateClass) -ExecutionParameters $executionParameters -BaseHead $BaseHead -CommitHash $CommitHash -ProductPath $observedDiffPath -CandidateMember $candidateMember)
    $chain = @(
        $discoveredCandidateClass,
        $GrantedCandidateClass,
        $ExecutorCandidateClass,
        $observedDiffClass,
        $ReceiptCandidateClass,
        $LearningProjectionClass
    )
    $matched = $immutableDiscoveryEvidencePresent -and -not [string]::IsNullOrWhiteSpace($discoveredCandidateClass) -and $candidatePathMatched -and $candidateMemberMatched -and $candidateExecutionParametersMatched
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
        "prBaseHead=$effectivePrBaseHead",
        "prBaseHeadPresent=$prBaseHeadPresent",
        "prBaseHeadMatched=$prBaseHeadMatched",
        "commitHash=$CommitHash",
        "executionCandidateDigest=$executionCandidateDigest",
        "candidateExecutionParametersMatched=$candidateExecutionParametersMatched",
        "discoveryEvidenceCreatedByCurrentProductPr=$discoveryEvidenceCreatedByCurrentProductPr",
        "discoveryEvidenceChangedInsideProductPr=$discoveryEvidenceChangedInsideProductPr",
        "discoveryEvidenceCommit=$discoveryEvidenceCommit",
        "discoveryEvidenceCommitIsAncestorOfBaseHead=$discoveryEvidenceCommitIsAncestorOfBaseHead",
        "externalDiscoverySignatureVerified=$externalDiscoverySignatureVerified",
        "discoveryEvidenceDigest=$discoveryEvidenceDigest",
        "discoveryEvidencePath=$DiscoveryEvidencePath"
    )

    return [ordered]@{
        schemaVersion = "threshold.petclinic.candidate-class-provenance.v0.1"
        discoveryObservation = if ($immutableDiscoveryEvidencePresent) { "immutable-discovery-evidence" } elseif ($candidate) { "untrusted-execution-snapshot-only" } else { "missing" }
        discoveryRuleId = $discoveryRuleId
        discoveryCandidateId = $CandidateId
        discoveryEvidence = $null
        discoveryEvidencePath = $DiscoveryEvidencePath
        discoveryEvidenceDigest = $discoveryEvidenceDigest
        prBaseHead = $effectivePrBaseHead
        prBaseHeadPresent = [bool]$prBaseHeadPresent
        prBaseHeadMatched = [bool]$prBaseHeadMatched
        discoveryEvidenceCreatedByCurrentProductPr = [bool]$discoveryEvidenceCreatedByCurrentProductPr
        discoveryEvidenceChangedInsideProductPr = [bool]$discoveryEvidenceChangedInsideProductPr
        discoveryEvidencePresentInBaseHead = [bool]$discoveryEvidencePresentInBaseHead
        discoveryEvidenceBaseDigestMatched = [bool]$discoveryEvidenceBaseDigestMatched
        discoveryEvidenceCommit = $discoveryEvidenceCommit
        discoveryEvidenceCommitIsAncestorOfBaseHead = [bool]$discoveryEvidenceCommitIsAncestorOfBaseHead
        discoveryEvidenceSourceBaseHead = $discoveryEvidenceSourceBaseHead
        discoveryEvidenceSourceBaseHeadIsAncestorOfBaseHead = [bool]$discoveryEvidenceSourceBaseHeadIsAncestorOfBaseHead
        externalDiscoverySignatureVerified = [bool]$externalDiscoverySignatureVerified
        discoveryEvidenceTrustRootVerified = [bool]$discoveryEvidenceTrustRootVerified
        immutableDiscoveryEvidencePresent = [bool]$immutableDiscoveryEvidencePresent
        fallbackToMutableCurrentPocket = $false
        fallbackToReceiptEmbeddedSnapshot = $false
        fallbackToReceiptSuppliedBooleans = $false
        executionCandidateSnapshot = $executionCandidateSnapshot
        executionCandidateDigest = $executionCandidateDigest
        discoveredCandidateClass = $discoveredCandidateClass
        grantedCandidateClass = $GrantedCandidateClass
        executorCandidateClass = $ExecutorCandidateClass
        independentlyObservedDiffClass = $observedDiffClass
        independentlyObservedDiffPath = $observedDiffPath
        candidatePathMatched = [bool]$candidatePathMatched
        candidateMemberMatched = [bool]$candidateMemberMatched
        candidateExecutionParametersMatched = [bool]$candidateExecutionParametersMatched
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
        [string] $PrBaseHead = "",
        [string] $CandidatePocketPath = "threshold/candidate-pocket/current.json",
        [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence"
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
    $receiptPrBaseHead = Get-ThresholdJsonProperty $provenance "prBaseHead" ""
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
        if ([string]::IsNullOrWhiteSpace([string]$PrBaseHead)) {
            throw "candidateClassProvenance prBaseHead missing from independent PR context receipt=$ReceiptPath"
        }
        if (-not (Test-ThresholdCommitIsAncestor -Ancestor ([string]$PrBaseHead) -Descendant ([string]$baseHead))) {
            throw "candidateClassProvenance prBaseHead is not ancestor of source baseHead receipt=$ReceiptPath prBaseHead=$PrBaseHead sourceBaseHead=$baseHead"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$receiptPrBaseHead) -and [string]$receiptPrBaseHead -ne [string]$PrBaseHead) {
            throw "candidateClassProvenance receipt prBaseHead claim mismatch receipt=$ReceiptPath receiptPrBaseHead=$receiptPrBaseHead observedPrBaseHead=$PrBaseHead"
        }

        if ($null -ne (Get-ThresholdJsonProperty $provenance "discoveryEvidence" $null)) {
            throw "candidateClassProvenance discovery evidence must be an external immutable artifact, not receipt-embedded evidence receipt=$ReceiptPath"
        }
        $embeddedSnapshot = Get-ThresholdJsonProperty $provenance "executionCandidateSnapshot" $null
        $discoveryEvidencePath = [string](Get-ThresholdJsonProperty $provenance "discoveryEvidencePath" "")
        if ([string]::IsNullOrWhiteSpace($discoveryEvidencePath)) {
            $discoveryEvidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot -CandidateId ([string]$candidateId) -BaseHead ([string]$baseHead)
        }
        $observedDiscoveryEvidence = Get-ThresholdCandidateDiscoveryEvidenceFromPath -Path $discoveryEvidencePath
        if ($null -eq $observedDiscoveryEvidence) {
            throw "candidateClassProvenance discovery evidence artifact missing receipt=$ReceiptPath path=$discoveryEvidencePath"
        }
        $observedDiscoveryEvidenceDigest = Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $observedDiscoveryEvidence
        if ([string]$observedDiscoveryEvidenceDigest -ne [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "discoveryEvidenceDigest" "")) {
            throw "candidateClassProvenance discovery evidence artifact digest mismatch receipt=$ReceiptPath"
        }
        if ([string](Get-ThresholdJsonProperty $provenance "discoveryEvidenceDigest" "") -ne [string]$observedDiscoveryEvidenceDigest) {
            throw "candidateClassProvenance discovery evidence digest mismatch receipt=$ReceiptPath"
        }
        if (Test-ThresholdPathChangedInRange -BaseHead ([string]$PrBaseHead) -CommitHash ([string]$commitHash) -Path $discoveryEvidencePath) {
            throw "candidateClassProvenance discovery evidence was added or modified inside current product PR receipt=$ReceiptPath path=$discoveryEvidencePath"
        }
        $baseDiscoveryEvidence = Get-ThresholdCandidateDiscoveryEvidenceFromRevision -Revision ([string]$PrBaseHead) -Path $discoveryEvidencePath
        if ($null -eq $baseDiscoveryEvidence) {
            throw "candidateClassProvenance discovery evidence must pre-exist in PR baseHead receipt=$ReceiptPath path=$discoveryEvidencePath"
        }
        $baseDiscoveryEvidenceDigest = Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $baseDiscoveryEvidence
        if ([string]$baseDiscoveryEvidenceDigest -ne [string]$observedDiscoveryEvidenceDigest) {
            throw "candidateClassProvenance discovery evidence was modified after PR baseHead receipt=$ReceiptPath path=$discoveryEvidencePath"
        }
        $discoveryEvidenceCommit = Get-ThresholdLastCommitTouchingPath -Revision ([string]$PrBaseHead) -Path $discoveryEvidencePath
        if (-not (Test-ThresholdCommitIsAncestor -Ancestor $discoveryEvidenceCommit -Descendant ([string]$PrBaseHead))) {
            throw "candidateClassProvenance discovery evidence commit is not ancestor of PR baseHead receipt=$ReceiptPath path=$discoveryEvidencePath"
        }
        $discoveryEvidenceSourceBaseHead = [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "baseHead" "")
        if (-not (Test-ThresholdCommitIsAncestor -Ancestor $discoveryEvidenceSourceBaseHead -Descendant ([string]$PrBaseHead))) {
            throw "candidateClassProvenance discovery evidence source baseHead is not ancestor of PR baseHead receipt=$ReceiptPath evidenceBaseHead=$discoveryEvidenceSourceBaseHead prBaseHead=$PrBaseHead"
        }
        foreach ($field in @("candidateId")) {
            Assert-ThresholdProvenanceFieldMatches -Observed $observedDiscoveryEvidence -Expected ([pscustomobject]@{ candidateId = $candidateId }) -Field $field -ReceiptPath $ReceiptPath
        }
        if ([string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidateClass" "") -ne [string](Get-ThresholdJsonProperty $provenance "discoveredCandidateClass" "")) {
            throw "candidateClassProvenance discovery evidence candidateClass mismatch receipt=$ReceiptPath"
        }
        if ([string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidatePath" "") -ne [string](Get-ThresholdJsonProperty $provenance "independentlyObservedDiffPath" "")) {
            throw "candidateClassProvenance discovery evidence candidatePath mismatch receipt=$ReceiptPath"
        }
        $observedDiscoveryPath = [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidatePath" "")
        $observedDiscoveryMember = [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidateMember" "")
        $observedHunkFingerprint = Get-ThresholdStringSha256Lower -Text "candidatePath=$observedDiscoveryPath`ncandidateMember=$observedDiscoveryMember"
        if ([string]$observedHunkFingerprint -ne [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidateHunkFingerprint" "")) {
            throw "candidateClassProvenance discovery evidence hunk fingerprint mismatch receipt=$ReceiptPath"
        }
        $observedExecutionParameters = Get-ThresholdJsonProperty $observedDiscoveryEvidence "executionParameters" ([ordered]@{})
        $observedExecutionParametersDigest = Get-ThresholdStringSha256Lower -Text (Get-ThresholdCanonicalExecutionParametersText -ExecutionParameters $observedExecutionParameters)
        if ([string]$observedExecutionParametersDigest -ne [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "executionParametersDigest" "")) {
            throw "candidateClassProvenance discovery evidence execution parameter digest mismatch receipt=$ReceiptPath"
        }
        if ($null -ne $embeddedSnapshot) {
            $embeddedDigest = Get-ThresholdCandidateSnapshotDigest -CandidateSnapshot $embeddedSnapshot
            if ([string]$embeddedDigest -ne [string](Get-ThresholdJsonProperty $provenance "executionCandidateDigest" "")) {
                throw "candidateClassProvenance execution snapshot digest mismatch receipt=$ReceiptPath embeddedDigest=$embeddedDigest provenanceDigest=$($provenance.executionCandidateDigest)"
            }
            if ([string]$embeddedDigest -ne [string](Get-ThresholdJsonProperty $observedDiscoveryEvidence "candidateSnapshotDigest" "")) {
                throw "candidateClassProvenance execution snapshot must reconcile to discovery evidence receipt=$ReceiptPath embeddedDigest=$embeddedDigest discoveryDigest=$($observedDiscoveryEvidence.candidateSnapshotDigest)"
            }
            if ([string](Get-ThresholdJsonProperty $embeddedSnapshot "candidateId" "") -ne [string]$candidateId) {
                throw "candidateClassProvenance execution snapshot candidateId mismatch receipt=$ReceiptPath candidateId=$candidateId embeddedCandidateId=$($embeddedSnapshot.candidateId)"
            }
            if ([string](Get-ThresholdJsonProperty $embeddedSnapshot "candidateClass" "") -ne [string](Get-ThresholdJsonProperty $provenance "discoveredCandidateClass" "")) {
                throw "candidateClassProvenance execution snapshot candidateClass mismatch receipt=$ReceiptPath embeddedCandidateClass=$($embeddedSnapshot.candidateClass) discoveredCandidateClass=$($provenance.discoveredCandidateClass)"
            }
            if (-not (Test-ThresholdExecutionParametersEqual -Observed (Get-ThresholdJsonProperty $embeddedSnapshot "executionParameters" ([ordered]@{})) -Expected $observedExecutionParameters)) {
                throw "candidateClassProvenance execution parameters must reconcile to discovery evidence receipt=$ReceiptPath"
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
            -PrBaseHead ([string]$PrBaseHead) `
            -CandidatePocketPath $CandidatePocketPath `
            -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot `
            -DiscoveryEvidencePath $discoveryEvidencePath

        foreach ($field in @(
            "discoveryObservation",
            "discoveryRuleId",
            "discoveryCandidateId",
            "discoveryEvidencePath",
            "discoveryEvidenceDigest",
            "prBaseHead",
            "prBaseHeadPresent",
            "prBaseHeadMatched",
            "discoveryEvidenceCreatedByCurrentProductPr",
            "discoveryEvidenceChangedInsideProductPr",
            "discoveryEvidencePresentInBaseHead",
            "discoveryEvidenceBaseDigestMatched",
            "discoveryEvidenceCommit",
            "discoveryEvidenceCommitIsAncestorOfBaseHead",
            "discoveryEvidenceSourceBaseHead",
            "discoveryEvidenceSourceBaseHeadIsAncestorOfBaseHead",
            "externalDiscoverySignatureVerified",
            "discoveryEvidenceTrustRootVerified",
            "immutableDiscoveryEvidencePresent",
            "fallbackToMutableCurrentPocket",
            "fallbackToReceiptEmbeddedSnapshot",
            "fallbackToReceiptSuppliedBooleans",
            "executionCandidateDigest",
            "discoveredCandidateClass",
            "grantedCandidateClass",
            "executorCandidateClass",
            "independentlyObservedDiffClass",
            "candidateExecutionParametersMatched",
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
    if ((Get-ThresholdJsonProperty $provenance "immutableDiscoveryEvidencePresent" $false) -ne $true) {
        return $false
    }
    foreach ($field in @("receiptAdmission", "kgMaterialization", "trainerMaterialization", "publicationAdmission", "promotionEvidenceContribution")) {
        if ((Get-ThresholdJsonProperty $provenance $field $false) -ne $true) {
            return $false
        }
    }
    return $true
}
