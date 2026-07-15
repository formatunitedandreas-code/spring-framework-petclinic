[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $PocketPath = "threshold/candidate-pocket/current.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $SourceRoot = "src/main/java/org/springframework/samples/petclinic",
    [int] $Limit = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LeaseScalar {
    param([string[]] $Lines, [string] $Name)
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { throw "Missing lease field '$Name' in $LeasePath" }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-LeaseList {
    param([string[]] $Lines, [string] $Name)
    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") {
            $inside = $true
            continue
        }
        if ($inside -and $line -match "^\S") { break }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") {
            $items.Add(($Matches[1]).Trim())
        }
    }
    return $items.ToArray()
}

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function New-CandidateId {
    param([string] $Path, [string] $CandidateClass, [string] $Member)
    $stem = "$Path-$CandidateClass-$Member".ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $stem.Trim("-")
}

function ConvertTo-ConstantName {
    param([string] $Name, [string] $Suffix)
    $snake = ($Name -creplace "([a-z0-9])([A-Z])", '$1_$2').ToUpperInvariant() -creplace "[^A-Z0-9]+", "_"
    $snake = $snake.Trim("_")
    if ([string]::IsNullOrWhiteSpace($snake)) { $snake = "VALUE" }
    return "$snake`_$Suffix"
}

function Test-StringConstantExists {
    param([string] $Content, [string] $ConstantName)
    return $Content -match "private\s+static\s+final\s+String\s+$([regex]::Escape($ConstantName))\s*="
}

function Get-FirstRepositoryQueryExpression {
    param([string] $MethodText)

    $match = [regex]::Match($MethodText, '(?s)\.sql\s*\(\s*(?<literal>"""(?:.*?)"""|"(?:[^"\\]|\\.)*")\s*\)')
    if ($match.Success) { return $match.Groups["literal"].Value }

    $match = [regex]::Match(
        $MethodText,
        '(?s)\.createQuery\s*\(\s*(?<literal>(?:"""(?:.*?)"""|"(?:[^"\\]|\\.)*")(?:\s*\+\s*(?:"""(?:.*?)"""|"(?:[^"\\]|\\.)*"))*)\s*,'
    )
    if (-not $match.Success) { return $null }
    return $match.Groups["literal"].Value
}

function Is-CandidateAllowed {
    param([string] $CandidateClass, [string[]] $AllowedTypes)
    return ($AllowedTypes.Count -eq 0) -or ($AllowedTypes -contains $CandidateClass)
}

function Get-AutoPatchableGate {
    param([string] $Path)

    $approved = @{}
    if (-not (Test-Path $Path)) {
        return $approved
    }

    $gate = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($entry in @($gate.approvedAutoPatchableCandidateClasses)) {
        if ($entry.candidateClass) {
            $approved[[string]$entry.candidateClass] = $entry
        }
    }
    return $approved
}

function Test-CandidateClassGate {
    param([string] $CandidateClass)
    return $script:ApprovedAutoPatchableCandidateClasses.ContainsKey($CandidateClass)
}

function Add-Candidate {
    param(
        [hashtable] $Candidate,
        [string] $CandidateClass,
        [string[]] $AllowedTypes,
        [System.Collections.Generic.List[object]] $Bucket
    )
    if (-not (Is-CandidateAllowed -CandidateClass $CandidateClass -AllowedTypes $AllowedTypes)) {
        return
    }
    $Candidate.candidateClass = $CandidateClass
    $Candidate.autoPatchable = Test-AutoPatchableCandidate $Candidate $CandidateClass
    $Candidate.reviewOnly = -not $Candidate.autoPatchable
    $Candidate.executionMode = if ($Candidate.autoPatchable) { "auto_patchable" } else { "review_only" }
    $Candidate.gate = [ordered]@{
        required = $true
        approved = Test-CandidateClassGate $CandidateClass
        gatePath = ConvertTo-RepoPath $GatePath
    }
    $Bucket.Add([pscustomobject]$Candidate)
}

function Test-AutoPatchableCandidate {
    param([hashtable] $Candidate, [string] $CandidateClass)
    if (-not (Test-CandidateClassGate $CandidateClass)) {
        return $false
    }
    if ($CandidateClass -eq "duplicate_literal_local_constant_extraction") {
        return $Candidate.ContainsKey("literal") -and $Candidate.ContainsKey("constantName")
    }
    if ($CandidateClass -eq "redundant_local_variable_simplification") {
        return $Candidate.ContainsKey("member") -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.member)
    }
    if ($CandidateClass -eq "private_helper_extraction_for_readability") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    if ($CandidateClass -eq "method_signature_wrap_cleanup") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    if ($CandidateClass -eq "repository_readability_cleanup") {
        if ($Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")) {
            return $true
        }
        return $Candidate.ContainsKey("sqlLiteral") -and
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.sqlLiteral) -and
            $Candidate.ContainsKey("constantName") -and
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.constantName)
    }
    if ($CandidateClass -eq "utility_readability_cleanup") {
        return $Candidate.ContainsKey("utilityPattern") -and
            [string]$Candidate.utilityPattern -eq "stopwatch_start_helper" -and
            $Candidate.ContainsKey("helperName") -and
            -not [string]::IsNullOrWhiteSpace([string]$Candidate.helperName)
    }
    if ($CandidateClass -eq "split_string_constant_normalization") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    if ($CandidateClass -eq "string_constant_wrap_cleanup") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    if ($CandidateClass -eq "method_spacing_normalization") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    if ($CandidateClass -eq "comment_wrap_cleanup") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-") -and $Candidate.ContainsKey("commentWrapSplitPointFound") -and $Candidate.commentWrapSplitPointFound -eq $true
    }
    if ($CandidateClass -eq "line_comment_wrap_cleanup") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-") -and $Candidate.ContainsKey("commentWrapSplitPointFound") -and $Candidate.commentWrapSplitPointFound -eq $true
    }
    if ($CandidateClass -eq "spring_data_query_wrap_cleanup") {
        return $Candidate.ContainsKey("member") -and ([string]$Candidate.member).StartsWith("line-")
    }
    return $false
}

function Test-SimpleStringConstantLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+";\s*$'
}

function Test-SplitStringConstantLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s+"[^"\\]+";\s*$'
}

function Test-SplitStringConstantStartLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+" \+\s*$'
}

function Test-SimpleQueryAnnotationLine {
    param([string] $Line)
    return $Line -match '^\s*@Query\("(?<value>[^"\\]+)"\)\s*$'
}

function Find-ConservativeCommentSplitPoint {
    param([string] $Text)

    $minimumPrefix = 24
    $minimumSegmentLength = 16
    $preferredMaxIndex = [Math]::Min(112, $Text.Length - 1)
    if ($preferredMaxIndex -lt $minimumPrefix) {
        return $null
    }

    $spaceSplit = $preferredMaxIndex
    while ($spaceSplit -ge $minimumPrefix) {
        $spaceSplit = $Text.LastIndexOf(" ", $spaceSplit)
        if ($spaceSplit -lt $minimumPrefix) {
            break
        }
        $beforeSplit = $Text.Substring(0, $spaceSplit)
        $lastInlineTagStart = $beforeSplit.LastIndexOf("{@")
        $lastInlineTagEnd = $beforeSplit.LastIndexOf("}")
        if ($lastInlineTagStart -gt $lastInlineTagEnd) {
            $spaceSplit--
            continue
        }
        if ($spaceSplit -lt ($Text.Length - 1) -and
            $spaceSplit -ge $minimumSegmentLength -and
            ($Text.Length - ($spaceSplit + 1)) -ge $minimumSegmentLength) {
            return [pscustomobject]@{
                Index = $spaceSplit
                KeepDelimiter = $false
            }
        }
        $spaceSplit--
    }

    return $null
}
function Parse-MethodBlocks {
    param([string[]] $Lines)
    $methods = New-Object System.Collections.Generic.List[psobject]

    $signaturePattern = "^\s*(public|private|protected)\s+[^({;]+\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\([^)]*\)\s*(?:throws\s+[^{]+)?\s*\{$"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $match = [regex]::Match($line, $signaturePattern)
        if (-not $match.Success) {
            continue
        }

        $methodName = $match.Groups[2].Value
        $braceDepth = 0
        $end = -1
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $text = $lines[$j]
            $braceDepth += ([regex]::Matches($text, '\{').Count - [regex]::Matches($text, '\}').Count)
            if ($j -gt $i -and $braceDepth -eq 0) {
                $end = $j
                break
            }
        }
        if ($end -lt 0) {
            continue
        }

        $methods.Add([pscustomobject]@{
            Name = $methodName
            StartLine = $i
            EndLine = $end
            Lines = $lines[$i..$end]
            Text = ($lines[$i..$end] -join "`r`n")
            LineCount = $end - $i + 1
        })

        $i = $end
    }

    return $methods
}

if (-not (Test-Path $LeasePath)) {
    throw "Lease file not found: $LeasePath"
}

$leaseLines = Get-Content $LeasePath
$leaseName = Get-LeaseScalar $leaseLines "leaseName"
$branch = Get-LeaseScalar $leaseLines "branch"
$head = (& git rev-parse HEAD).Trim()
$allowedCandidateTypes = Get-LeaseList $leaseLines "allowedCandidateTypes"
$script:ApprovedAutoPatchableCandidateClasses = Get-AutoPatchableGate -Path $GatePath

$sourceFiles = @(
    Get-ChildItem $SourceRoot -Recurse -Filter "*.java" |
        Where-Object {
            $_.FullName -notmatch "\\src\\test\\" -and
            $_.FullName -notmatch "\\target\\"
        } |
        Sort-Object FullName
)

$candidates = New-Object System.Collections.Generic.List[object]

foreach ($file in $sourceFiles) {
    $path = ConvertTo-RepoPath ($file.FullName.Substring((Get-Location).Path.Length + 1))
    $content = Get-Content $file.FullName -Raw
    $lines = Get-Content $file.FullName
    $layerScore = 0
    if ($path -like "*/service/*") { $layerScore = 8 }
    elseif ($path -like "*/repository/*") { $layerScore = 7 }
    elseif ($path -like "*/model/*") { $layerScore = 6 }
    elseif ($path -like "*/web/*") { $layerScore = 5 }
    elseif ($path -like "*/util/*") { $layerScore = 5 }

    # Heuristic 1: remove redundant local variable if assigned once and directly returned.
    $returnLocalPattern = "(?ms)(?<type>[A-Z][A-Za-z0-9_<>, ?]+)\s+(?<name>[a-z][A-Za-z0-9_]*)\s*=\s*(?<expr>[^;]+);\s*return\s+\k<name>\s*;"
    foreach ($match in [regex]::Matches($content, $returnLocalPattern)) {
        $member = $match.Groups["name"].Value
        $score = 30 + 30 + 20 + 12 + 10 + $layerScore
        Add-Candidate -CandidateClass "redundant_local_variable_simplification" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path "redundant_local_variable_simplification" $member
            score = $score
            file = $path
            member = $member
            expectedDiffSummary = "Inline local variable '$member' immediately returned from the same block."
            estimatedChangedLines = 2
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    # Heuristic 2: normalize already split string constants with poor inline wrapping.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not (Test-SplitStringConstantLine $lines[$i])) {
            continue
        }
        $member = "line-$($i + 1)"
        $score = 30 + 30 + 20 + 10 + $layerScore
        Add-Candidate -CandidateClass "split_string_constant_normalization" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path "split_string_constant_normalization" $member
            score = $score
            file = $path
            member = $member
            expectedDiffSummary = "Normalize a split string constant into a clean two-line wrap without changing its value."
            estimatedChangedLines = 2
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    # Heuristic 3: line readability cleanup for long statements.
    $longLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Length -gt 120 -and $lines[$i] -match "^\s*(private|public|return|[A-Za-z0-9_]+\.)") {
            $longLines += ($i + 1)
        }
    }
    if ($longLines.Count -gt 0) {
        $member = "line-$($longLines[0])"
        $candidateLine = $lines[$longLines[0] - 1]
        $candidateClass = $null
        if (Test-SimpleStringConstantLine $candidateLine) {
            $candidateClass = if ($path -like "*/repository/*") { "repository_readability_cleanup" } else { "string_constant_wrap_cleanup" }
        }
        elseif ($candidateLine -match "^\s*(public|private|protected)\s+.+\)\s*\{\s*$") {
            $candidateClass = "method_signature_wrap_cleanup"
        }
    }
    if ($longLines.Count -gt 0 -and $candidateClass) {
        $score = 30 + 30 + 20 + 10 + $layerScore
        Add-Candidate -CandidateClass $candidateClass -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path $candidateClass $member
            score = $score
            file = $path
            member = $member
                    expectedDiffSummary = "Wrap a long constant or method signature readability line without changing behavior."
                    estimatedChangedLines = [Math]::Min(8, $longLines.Count * 2)
                    tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
                })
    }

    # Heuristic 3b: Spring Data JPA query annotation readability cleanup.
    if ($path -like "*/repository/springdatajpa/*") {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Length -le 110) {
                continue
            }
            if (-not (Test-SimpleQueryAnnotationLine $lines[$i])) {
                continue
            }

            $member = "line-$($i + 1)"
            Add-Candidate -CandidateClass "spring_data_query_wrap_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
                candidateId = New-CandidateId $path "spring_data_query_wrap_cleanup" $member
                score = 30 + 30 + 20 + 10 + $layerScore
                file = $path
                member = $member
                expectedDiffSummary = "Wrap a long Spring Data @Query annotation into a concatenated two-line query literal without changing semantics."
                estimatedChangedLines = 2
                tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
            })
        }
    }

    # Heuristic 3c: repository split string constant continuation cleanup.
    if ($path -like "*/repository/*") {
        for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
            if ($lines[$i].Length -le 110) {
                continue
            }
            if (-not (Test-SplitStringConstantStartLine $lines[$i])) {
                continue
            }
            if ($lines[$i + 1] -notmatch '^\s*"[^"\\]+";\s*$') {
                continue
            }

            $member = "line-$($i + 1)"
            $constantMatch = [regex]::Match($lines[$i], '^\s*private static final String (?<name>[A-Z0-9_]+) =')
            $constantName = if ($constantMatch.Success) { $constantMatch.Groups["name"].Value } else { $null }
            Add-Candidate -CandidateClass "repository_readability_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
                candidateId = New-CandidateId $path "repository_readability_cleanup" $member
                score = 30 + 30 + 20 + 18 + $layerScore
                file = $path
                member = $member
                constantName = $constantName
                expectedDiffSummary = "Normalize a split repository string constant into a canonical two-line continuation format."
                estimatedChangedLines = 2
                tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
            })
        }
    }

    $methods = @(Parse-MethodBlocks -Lines $lines)

    # Heuristic 4: tiny spacing normalization between adjacent methods.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -le 100) {
            continue
        }
        if ($line -notmatch '^\s*\*\s+\S') {
            continue
        }
        $commentText = ($line -replace '^\s*\*\s+', '')
        if (-not (Find-ConservativeCommentSplitPoint -Text $commentText)) {
            continue
        }
        $member = "line-$($i + 1)"
        Add-Candidate -CandidateClass "comment_wrap_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path "comment_wrap_cleanup" $member
            score = 30 + 30 + 20 + 10 + $layerScore
            file = $path
            member = $member
            commentWrapSplitPointFound = $true
            expectedDiffSummary = "Wrap one long Javadoc comment line without changing source behavior."
            estimatedChangedLines = 2
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    # Heuristic 5: tiny spacing normalization between adjacent methods.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -le 120) {
            continue
        }
        if ($line -notmatch '^\s*//\s+\S') {
            continue
        }
        $commentText = ($line -replace '^\s*//\s+', '')
        if (-not (Find-ConservativeCommentSplitPoint -Text $commentText)) {
            continue
        }
        $member = "line-$($i + 1)"
        Add-Candidate -CandidateClass "line_comment_wrap_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path "line_comment_wrap_cleanup" $member
            score = 30 + 30 + 20 + 10 + $layerScore
            file = $path
            member = $member
            commentWrapSplitPointFound = $true
            expectedDiffSummary = "Wrap one long line comment without changing source behavior."
            estimatedChangedLines = 2
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    # Heuristic 6: tiny spacing normalization between adjacent methods.
    if ($methods.Count -gt 1) {
        for ($m = 0; $m -lt ($methods.Count - 1); $m++) {
            $currentMethod = $methods[$m]
            $nextMethod = $methods[$m + 1]
            if ($nextMethod.StartLine -eq ($currentMethod.EndLine + 1)) {
                $lineNumber = $currentMethod.EndLine + 1
                $member = "line-$lineNumber"
                Add-Candidate -CandidateClass "method_spacing_normalization" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
                    candidateId = New-CandidateId $path "method_spacing_normalization" "$($currentMethod.Name)-$($nextMethod.Name)-$member"
                    score = 30 + 30 + 20 + 10 + $layerScore
                    file = $path
                    member = $member
                    expectedDiffSummary = "Insert a blank line between adjacent methods '$($currentMethod.Name)' and '$($nextMethod.Name)'."
                    estimatedChangedLines = 1
                    tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = "$($currentMethod.Name)-$($nextMethod.Name)" }
                })
            }
        }
    }

    # Heuristic 7: repository-specific readability candidate.
    if ($path -like "*/repository/*") {
        foreach ($method in $methods) {
            $methodName = $method.Name
            $methodText = $method.Text
            $methodLineCount = $method.LineCount
            $hasSqlToken = [regex]::IsMatch($methodText, "(?i)\b(SELECT|INSERT|UPDATE|DELETE|MERGE)\b")
            $hasSqlQueryCall = [regex]::IsMatch($methodText, "(?i)\.sql\s*\(")
            $hasJdbcCall = [regex]::IsMatch($methodText, "(?i)\b(jdbcClient|jdbcTemplate|entityManager|queryFor|NamedParameterJdbcTemplate|createQuery)\b")
            $inlineSqlLiteral = Get-FirstRepositoryQueryExpression -MethodText $methodText
            if (-not $inlineSqlLiteral) {
                continue
            }
            if (($hasSqlToken -or $hasSqlQueryCall) -and ($hasJdbcCall -or $hasSqlQueryCall) -and ($methodLineCount -gt 8 -or $inlineSqlLiteral)) {
                $constantName = ConvertTo-ConstantName $methodName "SQL"
                if (Test-StringConstantExists -Content $content -ConstantName $constantName) {
                    continue
                }
                $expectedDiffSummary = if ($inlineSqlLiteral) {
                    "Extract inline SQL literal from repository method '$methodName' into a private constant."
                } else {
                    "Extract repository SQL/persistence readability chunk from method '$methodName' into a private helper."
                }
                Add-Candidate -CandidateClass "repository_readability_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
                    candidateId = New-CandidateId $path "repository_readability_cleanup" $methodName
                    score = 30 + 30 + 20 + 18 + $layerScore
                    file = $path
                    member = $methodName
                    sqlLiteral = $inlineSqlLiteral
                    constantName = $constantName
                    expectedDiffSummary = $expectedDiffSummary
                    estimatedChangedLines = if ($inlineSqlLiteral) { 4 } else { [Math]::Min(40, $methodLineCount) }
                    tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $methodName }
                })
            }
        }
    }

    # Heuristic 7: utility-specific readability candidate.
    if ($path -like "*/util/*") {
        foreach ($method in $methods) {
            $methodName = $method.Name
            $methodText = $method.Text
            $methodLineCount = $method.LineCount
            $hasTryFinally = [regex]::IsMatch($methodText, "(?s)\btry\b.*\bfinally\b")
            $hasStopWatch = [regex]::IsMatch($methodText, "(?i)\bStopWatch\b")
            $hasSynchronized = [regex]::IsMatch($methodText, "(?i)\bsynchronized\b")
            if ($methodLineCount -gt 8 -and (($hasTryFinally -and $hasStopWatch) -or $hasSynchronized -or $hasStopWatch)) {
                $utilityPattern = if ($hasStopWatch) { "stopwatch_start_helper" } else { "synchronized_helper" }
                $helperName = if ($hasStopWatch) { "startInvocationStopWatch" } else { "recordInvocation" }
                if ($content -match "private\s+StopWatch\s+$([regex]::Escape($helperName))\s*\(" -or
                    $content -match "private\s+[\w<>]+\s+$([regex]::Escape($helperName))\s*\(") {
                    continue
                }
                Add-Candidate -CandidateClass "utility_readability_cleanup" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
                    candidateId = New-CandidateId $path "utility_readability_cleanup" $methodName
                    score = 30 + 30 + 20 + 12 + $layerScore
                    file = $path
                    member = $methodName
                    utilityPattern = $utilityPattern
                    helperName = $helperName
                    expectedDiffSummary = "Extract utility control-flow or instrumentation concern from '$methodName' into private helper(s)."
                    estimatedChangedLines = [Math]::Min(36, $methodLineCount)
                    tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $methodName }
                })
            }
        }
    }

    # Heuristic 8: duplicate literal extraction.
    $stringMatches = [regex]::Matches($content, '"([^"\\\r\n]|\\.)+"') |
        ForEach-Object { $_.Value } |
        Where-Object {
            $_ -notmatch '^"/' -and
            $_ -notmatch '^"redirect:' -and
            $_ -cnotmatch '^"[A-Z_]+"$'
        } |
        Group-Object |
        Where-Object { $_.Count -ge 2 } |
        Sort-Object @{ Expression = { $_.Count }; Descending = $true }, Name

    foreach ($group in $stringMatches | Select-Object -First 2) {
        $literalName = ($group.Name.Trim('"') -replace "[^A-Za-z0-9]+", "-").Trim("-")
        if ([string]::IsNullOrWhiteSpace($literalName)) { continue }
        $constantName = ($literalName -creplace "([a-z])([A-Z])", '$1_$2').ToUpperInvariant() -creplace "[^A-Z0-9]+", "_"
        $constantName = $constantName.Trim("_")
        if ([string]::IsNullOrWhiteSpace($constantName)) { continue }
        $score = 30 + 30 + 20 + 10 + $layerScore
        Add-Candidate -CandidateClass "duplicate_literal_local_constant_extraction" -AllowedTypes $allowedCandidateTypes -Bucket $candidates -Candidate ([ordered]@{
            candidateId = New-CandidateId $path "duplicate_literal_local_constant_extraction" $literalName
            score = $score
            file = $path
            member = $literalName
            literal = $group.Name
            constantName = $constantName
            expectedDiffSummary = "Extract repeated literal $($group.Name) to a same-class private constant."
            estimatedChangedLines = 4
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $literalName }
        })
    }
}

$ranked = @(
    $candidates |
        Sort-Object `
            @{ Expression = { -[int]$_.score } }, `
            @{ Expression = { [int]$_.estimatedChangedLines } }, `
            @{ Expression = { [string]$_.candidateClass } }, `
            @{ Expression = { [string]$_.file } }, `
            @{ Expression = { [string]$_.member } } |
        Select-Object -First $Limit
)

$autoPatchableRanked = @($ranked | Where-Object { $_.autoPatchable })

$pocketDir = Split-Path $PocketPath -Parent
if ($pocketDir -and -not (Test-Path $pocketDir)) {
    New-Item -ItemType Directory -Path $pocketDir | Out-Null
}

$pocket = [ordered]@{
    schemaVersion = "threshold.petclinic.candidate-pocket.v0.2"
    leaseName = $leaseName
    branch = $branch
    generatedFromHead = $head
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    discovery = [ordered]@{
        method = "static-heuristic-scan"
        sourceRoot = ConvertTo-RepoPath $SourceRoot
        gatePath = ConvertTo-RepoPath $GatePath
        approvedAutoPatchableCandidateClasses = @($script:ApprovedAutoPatchableCandidateClasses.Keys | Sort-Object)
        scannedFiles = $sourceFiles.Count
        ranking = @(
            "score descending",
            "estimated changed lines ascending",
            "candidate class lexical",
            "file path lexical",
            "member lexical"
        )
        allowedCandidateTypes = $allowedCandidateTypes
    }
    candidates = $ranked
    nextRecommendedCandidateId = if ($ranked.Count -gt 0) { $ranked[0].candidateId } else { $null }
    nextAutoPatchableCandidateId = if ($autoPatchableRanked.Count -gt 0) { $autoPatchableRanked[0].candidateId } else { $null }
    nonClaims = @(
        "candidate pocket is not an implementation claim",
        "candidate pocket does not claim behavior preservation until slice validation passes",
        "no public readiness claim",
        "no public correctness claim",
        "no public security claim",
        "no public compliance claim"
    )
}

$pocket | ConvertTo-Json -Depth 12 | Set-Content $PocketPath

Write-Host "Threshold candidate pocket generated"
Write-Host "pocketPath=$(ConvertTo-RepoPath $PocketPath)"
Write-Host "branch=$branch"
Write-Host "head=$head"
Write-Host "candidateCount=$($ranked.Count)"
Write-Host "autoPatchableCandidateCount=$($autoPatchableRanked.Count)"
Write-Host "nextRecommendedCandidateId=$($pocket.nextRecommendedCandidateId)"
Write-Host "nextAutoPatchableCandidateId=$($pocket.nextAutoPatchableCandidateId)"
