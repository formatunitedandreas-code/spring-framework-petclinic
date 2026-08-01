[CmdletBinding()]
param(
    [string] $BaseRef = "main",
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")
. (Join-Path $PSScriptRoot "lib/pr-metadata-envelope.ps1")
. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")

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

function Get-GitRemotes {
    $remotes = @(& git remote 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($remotes | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
}

function ConvertTo-PrVisibleBaseRef {
    param([string] $Ref, [string] $ObservedPrBaseRef = "")

    if ([string]::IsNullOrWhiteSpace($Ref)) { return "" }
    $trimmedRef = $Ref.Trim()
    if (-not [string]::IsNullOrWhiteSpace($ObservedPrBaseRef) -and $trimmedRef.EndsWith("/$ObservedPrBaseRef")) {
        return $ObservedPrBaseRef
    }
    if ($trimmedRef -match "^(origin)/(.+)$") {
        return $Matches[2]
    }
    return $trimmedRef
}

function ConvertTo-RemoteIndependentLeaseBaseRef {
    param([string] $Ref)

    if ([string]::IsNullOrWhiteSpace($Ref)) { return "" }
    $trimmedRef = $Ref.Trim()
    if ($trimmedRef -match "^([^/]+)/(?<branch>threshold-governed-refactor-demo-\d+-discovery-base)$") {
        return $Matches["branch"]
    }
    return (ConvertTo-PrVisibleBaseRef -Ref $trimmedRef)
}

function ConvertTo-OriginResolvedEvidenceRef {
    param([string] $Ref)

    $remoteIndependentRef = ConvertTo-RemoteIndependentLeaseBaseRef -Ref $Ref
    if ([string]::IsNullOrWhiteSpace($remoteIndependentRef)) { return "" }
    if ($remoteIndependentRef -match "^[0-9a-f]{40}$" -or $remoteIndependentRef -like "refs/*") {
        return $remoteIndependentRef
    }
    if ($remoteIndependentRef -match "^origin/.+$") {
        return $remoteIndependentRef
    }
    return "origin/$remoteIndependentRef"
}

function Resolve-BaseRefForGit {
    param([string] $Ref)

    if ([string]::IsNullOrWhiteSpace($Ref)) { return "" }
    $trimmedRef = $Ref.Trim()
    $remotes = @(Get-GitRemotes)
    if ($trimmedRef -match "^[0-9a-f]{40}$" -or $trimmedRef -like "refs/*") {
        return $trimmedRef
    }
    if ($trimmedRef -match "^([^/]+)/(.+)$" -and ($remotes -contains $Matches[1])) {
        return $trimmedRef
    }
    return "origin/$trimmedRef"
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

function Get-ReceiptChangedFiles {
    param([pscustomobject] $Receipt)

    return @(
        $Receipt.changedFiles | ForEach-Object {
            if ($_ -is [string]) {
                ConvertTo-RepoPath $_
            }
            elseif ($null -ne $_.path) {
                ConvertTo-RepoPath ([string]$_.path)
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    )
}

function Get-ReceiptChangedFileRecords {
    param([pscustomobject] $Receipt)

    $records = @(
        $Receipt.changedFiles | ForEach-Object {
            if ($_ -is [string]) {
                [pscustomobject]@{
                    path = ConvertTo-RepoPath $_
                    beforeSha256 = ""
                    afterSha256 = ""
                }
            }
            elseif ($null -ne $_.path) {
                [pscustomobject]@{
                    path = ConvertTo-RepoPath ([string]$_.path)
                    beforeSha256 = if ($null -ne $_.beforeSha256) { [string]$_.beforeSha256 } else { "" }
                    afterSha256 = if ($null -ne $_.afterSha256) { [string]$_.afterSha256 } else { "" }
                }
            }
        }
    )
    if ($Receipt.PSObject.Properties["candidates"] -and $null -ne $Receipt.candidates) {
        $records += @(
            $Receipt.candidates | ForEach-Object {
                if ($null -ne $_.file) {
                    [pscustomobject]@{
                        path = ConvertTo-RepoPath ([string]$_.file)
                        beforeSha256 = if ($null -ne $_.beforeSha256) { [string]$_.beforeSha256 } else { "" }
                        afterSha256 = if ($null -ne $_.afterSha256) { [string]$_.afterSha256 } else { "" }
                    }
                }
            }
        )
    }

    return @($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.path) })
}

function Get-ObservedCandidateDiffClassForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash,
        [Parameter(Mandatory = $true)]
        [string] $ProductPath
    )

    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $ProductPath)
    if (Test-ThresholdBlankLinePackageImportDiff -DiffLines $diffLines) { return "import_spacing_normalization" }
    if (Test-ThresholdMethodSpacingDiff -DiffLines $diffLines) { return "method_spacing_normalization" }
    if (Test-ThresholdStringConstantWrapDiff -DiffLines $diffLines) { return "string_constant_wrap_cleanup" }
    if (Test-ThresholdSplitStringConstantNormalizationDiff -DiffLines $diffLines) { return "split_string_constant_normalization" }
    if (Test-ThresholdCommentWrapDiff -DiffLines $diffLines) { return "comment_wrap_cleanup" }
    if (Test-ThresholdLineCommentWrapDiff -DiffLines $diffLines) { return "line_comment_wrap_cleanup" }
    if (Test-ThresholdBootstrapInvocationWrapDiff -DiffLines $diffLines) { return "application_bootstrap_readability_cleanup" }
    if (Test-ThresholdAnnotationAttributeWrapDiff -DiffLines $diffLines) { return "annotation_attribute_wrap_cleanup" }
    if (Test-ThresholdLeadingTabIndentationDiff -DiffLines $diffLines -BaseHead $BaseHead -ProductPath $ProductPath) { return "leading_tab_indentation_cleanup" }
    return "unknown"
}

function Test-ThresholdRepeatedCommentWrapDiff {
    param([string[]] $DiffLines)

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $DiffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*\*\s+\S' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*\*\s+\S' })
    $nonCommentDelta = @($contentLines | Where-Object {
        ($_ -match '^[+-]' -and $_ -notmatch '^[+-]\s*\*\s+\S')
    })
    if ($removed.Count -lt 1 -or $added.Count -ne ($removed.Count * 2) -or $nonCommentDelta.Count -ne 0) {
        return $false
    }
    $removedText = ConvertTo-ThresholdCollapsedWhitespace (($removed | ForEach-Object {
        Get-ThresholdCommentPayload -Line $_ -PrefixPattern '^[+-]\s*\*\s*'
    }) -join " ")
    $addedText = ConvertTo-ThresholdCollapsedWhitespace (($added | ForEach-Object {
        Get-ThresholdCommentPayload -Line $_ -PrefixPattern '^[+-]\s*\*\s*'
    }) -join " ")
    return $removedText -eq $addedText
}

function Get-ObservedBatchCandidateDiffClassForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseHead,
        [Parameter(Mandatory = $true)]
        [string] $CommitHash,
        [Parameter(Mandatory = $true)]
        [string] $ProductPath
    )

    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $ProductPath)
    if (Test-ThresholdRepeatedCommentWrapDiff -DiffLines $diffLines) { return "comment_wrap_cleanup" }
    return (Get-ObservedCandidateDiffClassForPath -BaseHead $BaseHead -CommitHash $CommitHash -ProductPath $ProductPath)
}

function Assert-RepeatedCommentWrapDiffMatchesCandidates {
    param(
        [string] $BaseHead,
        [string] $CommitHash,
        [string] $ProductPath,
        [object[]] $PathCandidates,
        [string] $ReceiptPath
    )

    $diffLines = @(& git diff --unified=3 "$BaseHead..$CommitHash" -- $ProductPath)
    if (-not (Test-ThresholdRepeatedCommentWrapDiff -DiffLines $diffLines)) {
        throw "Batch repeated comment wrap diff did not match expected shape receipt=$ReceiptPath file=$ProductPath"
    }
    $removedLineNumbers = @(Get-ThresholdDiffRemovedLineNumbers -DiffLines $diffLines)
    $candidateLineNumbers = @(
        $PathCandidates | ForEach-Object {
            $candidateId = [string](Get-ThresholdJsonProperty $_ "candidateId" "")
            $candidateMember = [string](Get-ThresholdJsonProperty $_ "member" "")
            if (-not $candidateMember.StartsWith("line-")) {
                throw "Batch repeated comment wrap candidate must use line member receipt=$ReceiptPath candidateId=$candidateId member=$candidateMember"
            }
            [int]($candidateMember.Substring(5))
        } | Sort-Object
    )
    if (($removedLineNumbers -join ",") -ne ($candidateLineNumbers -join ",")) {
        throw "Batch repeated comment wrap candidate line mismatch receipt=$ReceiptPath file=$ProductPath removedLines=[$($removedLineNumbers -join ', ')] candidateLines=[$($candidateLineNumbers -join ', ')]"
    }

    $contentLines = Get-ThresholdDiffContentLines -DiffLines $diffLines
    $removed = @($contentLines | Where-Object { $_ -match '^-\s*\*\s+\S' })
    $added = @($contentLines | Where-Object { $_ -match '^\+\s*\*\s+\S' })
    if ($removed.Count -ne $PathCandidates.Count -or $added.Count -ne ($PathCandidates.Count * 2)) {
        throw "Batch repeated comment wrap count mismatch receipt=$ReceiptPath file=$ProductPath removedCount=$($removed.Count) addedCount=$($added.Count) candidateCount=$($PathCandidates.Count)"
    }
    for ($i = 0; $i -lt $removed.Count; $i++) {
        $removedText = ConvertTo-ThresholdCollapsedWhitespace (Get-ThresholdCommentPayload -Line $removed[$i] -PrefixPattern '^[+-]\s*\*\s*')
        $addedText = ConvertTo-ThresholdCollapsedWhitespace ((@($added[$i * 2], $added[($i * 2) + 1]) | ForEach-Object {
            Get-ThresholdCommentPayload -Line $_ -PrefixPattern '^[+-]\s*\*\s*'
        }) -join " ")
        if ($removedText -ne $addedText) {
            $candidateId = [string](Get-ThresholdJsonProperty $PathCandidates[$i] "candidateId" "")
            throw "Batch repeated comment wrap per-candidate text mismatch receipt=$ReceiptPath candidateId=$candidateId file=$ProductPath line=$($removedLineNumbers[$i])"
        }
    }
}

function Assert-BatchCandidateMutationsMatchSourceCommit {
    param(
        [pscustomobject] $Receipt,
        [string] $ReceiptPath,
        [string] $SourceCommit
    )

    $batchId = Get-ThresholdJsonProperty $Receipt "batchId" $null
    if ([string]::IsNullOrWhiteSpace([string]$batchId)) { return }

    $parentHead = (& git rev-parse "$SourceCommit^1" 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$parentHead)) {
        throw "Batch candidate source commit parent unavailable receipt=$ReceiptPath sourceCommit=$SourceCommit"
    }
    $parentHead = ([string]$parentHead).Trim()
    $changedPaths = @(git diff-tree --no-commit-id --name-only -r $SourceCommit | ForEach-Object { ConvertTo-RepoPath $_ })
    $candidates = @(Get-ThresholdJsonProperty $Receipt "candidates" @())
    if ($candidates.Count -eq 0) {
        throw "Batch receipt is missing per-candidate entries: $ReceiptPath"
    }

    $actualProductPaths = @($changedPaths | Where-Object { Test-ProductPath -Path $_ } | Sort-Object -Unique)
    $candidateProductPaths = New-Object System.Collections.Generic.HashSet[string]
    $candidatesByPath = @{}
    foreach ($candidate in $candidates) {
        $candidateId = [string](Get-ThresholdJsonProperty $candidate "candidateId" "")
        $candidateClass = [string](Get-ThresholdJsonProperty $candidate "candidateClass" "")
        $candidatePath = ConvertTo-RepoPath ([string](Get-ThresholdJsonProperty $candidate "file" ""))
        $beforeSha256 = [string](Get-ThresholdJsonProperty $candidate "beforeSha256" "")
        $afterSha256 = [string](Get-ThresholdJsonProperty $candidate "afterSha256" "")
        if ([string]::IsNullOrWhiteSpace($candidateId)) {
            throw "Batch candidate is missing candidateId receipt=$ReceiptPath"
        }
        if ([string]::IsNullOrWhiteSpace($candidateClass)) {
            throw "Batch candidate is missing candidateClass receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            throw "Batch candidate is missing file receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ($changedPaths -notcontains $candidatePath) {
            throw "Batch candidate file was not changed by source commit receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath"
        }
        if (Test-ProductPath -Path $candidatePath) {
            [void]$candidateProductPaths.Add($candidatePath)
        }
        if ([string]::IsNullOrWhiteSpace($beforeSha256) -or [string]::IsNullOrWhiteSpace($afterSha256)) {
            throw "Batch candidate is missing beforeSha256/afterSha256 receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath"
        }
        if ($beforeSha256.ToLowerInvariant() -eq $afterSha256.ToLowerInvariant()) {
            throw "Batch candidate beforeSha256 equals afterSha256 receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath"
        }
        if (-not $candidatesByPath.ContainsKey($candidatePath)) {
            $candidatesByPath[$candidatePath] = New-Object System.Collections.Generic.List[object]
        }
        $candidatesByPath[$candidatePath].Add($candidate)
    }

    foreach ($candidatePath in $candidatesByPath.Keys) {
        $pathCandidates = @($candidatesByPath[$candidatePath].ToArray())
        $actualBeforeSha256 = (Get-CommitPathBlobSha256 -Commit $parentHead -Path $candidatePath).ToLowerInvariant()
        $actualAfterSha256 = (Get-CommitPathBlobSha256 -Commit $SourceCommit -Path $candidatePath).ToLowerInvariant()
        $firstCandidate = $pathCandidates[0]
        $lastCandidate = $pathCandidates[$pathCandidates.Count - 1]
        $firstBeforeSha256 = ([string](Get-ThresholdJsonProperty $firstCandidate "beforeSha256" "")).ToLowerInvariant()
        $lastAfterSha256 = ([string](Get-ThresholdJsonProperty $lastCandidate "afterSha256" "")).ToLowerInvariant()
        if ($firstBeforeSha256 -ne $actualBeforeSha256) {
            throw "Batch candidate path first beforeSha256 mismatch receipt=$ReceiptPath file=$candidatePath claimed=$firstBeforeSha256 actual=$actualBeforeSha256"
        }
        if ($lastAfterSha256 -ne $actualAfterSha256) {
            throw "Batch candidate path final afterSha256 mismatch receipt=$ReceiptPath file=$candidatePath claimed=$lastAfterSha256 actual=$actualAfterSha256"
        }
        for ($i = 1; $i -lt $pathCandidates.Count; $i++) {
            $previousAfterSha256 = ([string](Get-ThresholdJsonProperty $pathCandidates[$i - 1] "afterSha256" "")).ToLowerInvariant()
            $currentBeforeSha256 = ([string](Get-ThresholdJsonProperty $pathCandidates[$i] "beforeSha256" "")).ToLowerInvariant()
            if ($previousAfterSha256 -ne $currentBeforeSha256) {
                $candidateId = [string](Get-ThresholdJsonProperty $pathCandidates[$i] "candidateId" "")
                throw "Batch candidate same-path hash chain mismatch receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath previousAfterSha256=$previousAfterSha256 currentBeforeSha256=$currentBeforeSha256"
            }
        }

        $candidateClass = [string](Get-ThresholdJsonProperty $firstCandidate "candidateClass" "")
        $observedClass = Get-ObservedBatchCandidateDiffClassForPath -BaseHead $parentHead -CommitHash $SourceCommit -ProductPath $candidatePath
        if ([string]$observedClass -ne [string]$candidateClass) {
            throw "Batch candidate observed diff class mismatch receipt=$ReceiptPath file=$candidatePath candidateClass=$candidateClass observedDiffClass=$observedClass"
        }
        if ($pathCandidates.Count -gt 1 -and [string]$candidateClass -eq "comment_wrap_cleanup") {
            Assert-RepeatedCommentWrapDiffMatchesCandidates -BaseHead $parentHead -CommitHash $SourceCommit -ProductPath $candidatePath -PathCandidates $pathCandidates -ReceiptPath $ReceiptPath
        }
        if ($pathCandidates.Count -eq 1) {
            $candidate = $pathCandidates[0]
            $candidateId = [string](Get-ThresholdJsonProperty $candidate "candidateId" "")
            $candidateMember = [string](Get-ThresholdJsonProperty $candidate "member" "")
            if (-not (Test-ThresholdObservedDiffMemberMatchesCandidate -BaseHead $parentHead -CommitHash $SourceCommit -ProductPath $candidatePath -CandidateMember $candidateMember)) {
                throw "Batch candidate observed diff member mismatch receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath member=$candidateMember"
            }
            $executionParameters = Get-ThresholdCandidateExecutionParameters -Candidate $candidate
            if (-not (Test-ThresholdCandidateExecutionParametersMatchObservedDiff -CandidateClass $candidateClass -ExecutionParameters $executionParameters -BaseHead $parentHead -CommitHash $SourceCommit -ProductPath $candidatePath)) {
                throw "Batch candidate execution parameters mismatch receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath"
            }
        }
    }

    $uncoveredProductPaths = @($actualProductPaths | Where-Object { -not $candidateProductPaths.Contains($_) })
    if ($uncoveredProductPaths.Count -gt 0) {
        throw "Batch source commit has product changes without candidate coverage receipt=$ReceiptPath sourceCommit=$SourceCommit missing=[$($uncoveredProductPaths -join ', ')]"
    }
}

function Assert-PromotionSquashCommitCoveredByReceipts {
    param(
        [string] $Commit,
        [object[]] $ReceiptEntries,
        [string] $PromotionBaseHead = ""
    )

    $actualProductPaths = @(git diff-tree --no-commit-id --name-only -r $Commit | Where-Object { Test-ProductPath -Path $_ } | ForEach-Object { ConvertTo-RepoPath $_ } | Sort-Object -Unique)
    if ($actualProductPaths.Count -eq 0) {
        return
    }
    if ($ReceiptEntries.Count -eq 0) {
        throw "Promotion squash commit has product changes but no source receipts: $Commit"
    }

    $currentWaveReceiptEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $ReceiptEntries) {
        if (-not [string]::IsNullOrWhiteSpace($PromotionBaseHead) -and
            -not (Test-ThresholdPathChangedInRange -BaseHead $PromotionBaseHead -CommitHash "HEAD" -Path ([string]$entry.path))) {
            continue
        }
        $entryProductPaths = @(Get-ReceiptChangedFileRecords -Receipt $entry.receipt | Where-Object { Test-ProductPath -Path $_.path })
        if ($entryProductPaths.Count -gt 0) {
            $currentWaveReceiptEntries.Add($entry)
        }
    }
    if ($currentWaveReceiptEntries.Count -eq 0) {
        throw "Promotion squash commit has no current-wave product source receipts: $Commit"
    }

    $coveredProductPaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($entry in $currentWaveReceiptEntries.ToArray()) {
        $entryProductPaths = @(Get-ReceiptChangedFileRecords -Receipt $entry.receipt | Where-Object { Test-ProductPath -Path $_.path })
        foreach ($changedFile in $entryProductPaths) {
            $path = [string]$changedFile.path
            [void]$coveredProductPaths.Add($path)
        }
    }

    $missing = @($actualProductPaths | Where-Object { -not $coveredProductPaths.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "Promotion squash commit is not covered by source receipt changedFiles. commit=$Commit missing=[$($missing -join ', ')]"
    }

    foreach ($path in $actualProductPaths) {
        $actualAfterSha256 = (Get-CommitPathBlobSha256 -Commit $Commit -Path $path).ToLowerInvariant()
        $pathMatched = $false
        foreach ($entry in $currentWaveReceiptEntries.ToArray()) {
            $matchingChangedFiles = @(
                Get-ReceiptChangedFileRecords -Receipt $entry.receipt |
                    Where-Object {
                        [string]$_.path -eq [string]$path -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.afterSha256)
                    }
            )
            foreach ($changedFile in $matchingChangedFiles) {
                if ([string]$changedFile.afterSha256.ToLowerInvariant() -eq $actualAfterSha256) {
                    $pathMatched = $true
                    break
                }
            }
            if ($pathMatched) { break }
        }
        if (-not $pathMatched) {
            throw "Promotion squash commit content mismatch for receipt-covered path. commit=$Commit path=$path actualAfterSha256=$actualAfterSha256"
        }
    }

    Write-Host "promotionSquashReceiptReconciliation=passed"
    Write-Host "promotionSquashContentReconciliation=passed"
    Write-Host "promotionSquashCommit=$Commit"
    return @($currentWaveReceiptEntries.ToArray())
}

function Assert-BatchCandidateDiscoveryEvidenceMatchesPrBase {
    param(
        [pscustomobject] $Receipt,
        [string] $ReceiptPath,
        [string] $PrBaseHead,
        [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence"
    )

    $batchId = Get-ThresholdJsonProperty $Receipt "batchId" $null
    if ([string]::IsNullOrWhiteSpace([string]$batchId)) { return }

    $sourceCommit = [string](Get-ThresholdJsonProperty $Receipt "sourceCommit" "")
    $baseHead = [string](Get-ThresholdJsonProperty $Receipt "baseHead" "")
    if ([string]::IsNullOrWhiteSpace($sourceCommit)) {
        $sourceCommit = [string](Get-ThresholdJsonProperty $Receipt "commitHash" "")
    }
    if ([string]::IsNullOrWhiteSpace($sourceCommit)) {
        throw "Batch receipt is missing sourceCommit: $ReceiptPath"
    }
    if ([string]::IsNullOrWhiteSpace($baseHead)) {
        throw "Batch receipt is missing baseHead: $ReceiptPath"
    }
    if ([string]::IsNullOrWhiteSpace($PrBaseHead)) {
        throw "Batch receipt requires independent PR base context: $ReceiptPath"
    }
    if (-not (Test-ThresholdCommitIsAncestor -Ancestor $PrBaseHead -Descendant $baseHead)) {
        throw "Batch receipt PR base is not ancestor of source baseHead receipt=$ReceiptPath prBaseHead=$PrBaseHead sourceBaseHead=$baseHead"
    }

    $parentHead = (& git rev-parse "$sourceCommit^1" 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$parentHead)) {
        throw "Batch receipt source commit parent unavailable receipt=$ReceiptPath sourceCommit=$sourceCommit"
    }
    if ([string]$baseHead -ne [string]($parentHead.Trim())) {
        throw "Batch receipt baseHead mismatch receipt=$ReceiptPath baseHead=$baseHead parentHead=$([string]($parentHead.Trim()))"
    }

    $candidates = @(Get-ThresholdJsonProperty $Receipt "candidates" @())
    if ($candidates.Count -eq 0) {
        throw "Batch receipt is missing per-candidate entries: $ReceiptPath"
    }

    $changedPaths = @(git diff-tree --no-commit-id --name-only -r $sourceCommit | ForEach-Object { ConvertTo-RepoPath $_ })
    foreach ($candidate in $candidates) {
        $candidateId = [string](Get-ThresholdJsonProperty $candidate "candidateId" "")
        $candidateClass = [string](Get-ThresholdJsonProperty $candidate "candidateClass" "")
        $candidatePath = ConvertTo-RepoPath ([string](Get-ThresholdJsonProperty $candidate "file" ""))
        $candidateMember = [string](Get-ThresholdJsonProperty $candidate "member" "")
        if ([string]::IsNullOrWhiteSpace($candidateId)) {
            throw "Batch candidate is missing candidateId receipt=$ReceiptPath"
        }
        if ([string]::IsNullOrWhiteSpace($candidateClass)) {
            throw "Batch candidate is missing candidateClass receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            throw "Batch candidate is missing file receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ($changedPaths -notcontains $candidatePath) {
            throw "Batch candidate file was not changed by source commit receipt=$ReceiptPath candidateId=$candidateId file=$candidatePath"
        }

        $binding = Get-ThresholdJsonProperty $candidate "candidateDiscoveryEvidence" $null
        if ($null -eq $binding) {
            throw "Batch candidate is missing discovery evidence binding receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ((Get-ThresholdJsonProperty $binding "immutableDiscoveryEvidencePresent" $false) -ne $true) {
            throw "Batch candidate discovery evidence is not immutable receipt=$ReceiptPath candidateId=$candidateId"
        }
        $bindingPrBaseHead = [string](Get-ThresholdJsonProperty $binding "prBaseHead" "")
        if ([string]$bindingPrBaseHead -ne [string]$PrBaseHead) {
            throw "Batch candidate discovery evidence PR base mismatch receipt=$ReceiptPath candidateId=$candidateId bindingPrBaseHead=$bindingPrBaseHead observedPrBaseHead=$PrBaseHead"
        }
        $discoverySourceHead = [string](Get-ThresholdJsonProperty $binding "discoverySourceHead" "")
        if (-not (Test-ThresholdCommitIsAncestor -Ancestor $discoverySourceHead -Descendant $PrBaseHead)) {
            throw "Batch candidate discovery source is not ancestor of PR base receipt=$ReceiptPath candidateId=$candidateId discoverySourceHead=$discoverySourceHead prBaseHead=$PrBaseHead"
        }

        $evidencePath = [string](Get-ThresholdJsonProperty $binding "discoveryEvidencePath" "")
        if ([string]::IsNullOrWhiteSpace($evidencePath)) {
            $evidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot -CandidateId $candidateId -BaseHead $baseHead
        }
        if (Test-ThresholdPathChangedInRange -BaseHead $PrBaseHead -CommitHash $sourceCommit -Path $evidencePath) {
            throw "Batch candidate discovery evidence was added or modified inside current product PR receipt=$ReceiptPath candidateId=$candidateId path=$evidencePath"
        }

        $baseDiscoveryEvidence = Get-ThresholdCandidateDiscoveryEvidenceFromRevision -Revision $PrBaseHead -Path $evidencePath
        if ($null -eq $baseDiscoveryEvidence) {
            throw "Batch candidate discovery evidence must pre-exist in PR baseHead receipt=$ReceiptPath candidateId=$candidateId path=$evidencePath"
        }
        $baseDiscoveryEvidenceDigest = Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $baseDiscoveryEvidence
        if ([string]$baseDiscoveryEvidenceDigest -ne [string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "discoveryEvidenceDigest" "")) {
            throw "Batch candidate discovery evidence artifact digest mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string]$baseDiscoveryEvidenceDigest -ne [string](Get-ThresholdJsonProperty $binding "discoveryEvidenceDigest" "")) {
            throw "Batch candidate discovery evidence digest mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "baseHead" "") -ne [string]$discoverySourceHead) {
            throw "Batch candidate discovery evidence source head mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "candidateId" "") -ne [string]$candidateId) {
            throw "Batch candidate discovery evidence candidateId mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "candidateClass" "") -ne [string]$candidateClass) {
            throw "Batch candidate discovery evidence candidateClass mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if (ConvertTo-RepoPath ([string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "candidatePath" "")) -ne $candidatePath) {
            throw "Batch candidate discovery evidence candidatePath mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
        if ([string](Get-ThresholdJsonProperty $baseDiscoveryEvidence "candidateMember" "") -ne [string]$candidateMember) {
            throw "Batch candidate discovery evidence candidateMember mismatch receipt=$ReceiptPath candidateId=$candidateId"
        }
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

    $receiptCommits = @(git log --format=%H "$resolvedBaseRefForGit..HEAD" -- $ReceiptPath)
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
$resolvedBaseRefForGit = Resolve-BaseRefForGit -Ref $BaseRef
$prVisibleBaseRef = ConvertTo-PrVisibleBaseRef -Ref $BaseRef
$expectedPrVisibleBaseRef = ConvertTo-PrVisibleBaseRef -Ref $expectedBaseRef -ObservedPrBaseRef $prVisibleBaseRef
$remoteIndependentExpectedBaseRef = ConvertTo-RemoteIndependentLeaseBaseRef -Ref $expectedBaseRef

$preCommitWorktreeMode = $false
$changedPaths = @(git diff --name-only "$resolvedBaseRefForGit...HEAD")
if ($changedPaths.Count -eq 0) {
    $changedPaths = @(git diff --name-only HEAD)
    $preCommitWorktreeMode = $changedPaths.Count -gt 0
}
if ($changedPaths.Count -eq 0) { throw "No changed paths detected for the pull request." }

$governancePolicyPaths = @($changedPaths | Where-Object { Test-ThresholdGovernancePolicyPath -Path $_ })
$governanceEvidencePaths = @($changedPaths | Where-Object { Test-ThresholdGovernanceEvidencePath -Path $_ })
$leasePaths = @($changedPaths | Where-Object { Test-LeasePath $_ })
$productPaths = @($changedPaths | Where-Object { Test-ProductPath $_ })
$stackedGovernanceOnlyPr = $BaseRef -like "codex/*" -and $productPaths.Count -eq 0 -and @($changedPaths | Where-Object { -not (Test-ThresholdGovernancePath -Path $_) }).Count -eq 0
$governedEvidenceBasePromotionPr = $prVisibleBaseRef -ne $expectedPrVisibleBaseRef -and
    $remoteIndependentExpectedBaseRef -match "^threshold-governed-refactor-demo-\d+-discovery-base$" -and
    $productPaths.Count -gt 0 -and
    $governanceEvidencePaths.Count -gt 0
if ($prVisibleBaseRef -ne $expectedPrVisibleBaseRef -and -not $stackedGovernanceOnlyPr -and -not $governedEvidenceBasePromotionPr) {
    throw "PR base ref '$BaseRef' does not match threshold baseRef '$expectedBaseRef'."
}
if ($governancePolicyPaths.Count -gt 0 -and $productPaths.Count -gt 0) {
    throw "PR mixes governance policy and product paths; split into separate governed changes."
}

$requiresMergeAuthority = $governancePolicyPaths.Count -gt 0 -or ($leasePaths.Count -gt 0 -and $productPaths.Count -eq 0)
$mergeAuthoritySatisfied = $true
if ($requiresMergeAuthority) {
    if ($mergeAllowed -ne "true") {
        $mergeAuthoritySatisfied = $false
    }
    if ($forbiddenActions -contains "merge") {
        $mergeAuthoritySatisfied = $false
    }
    if (-not $mergeAuthoritySatisfied) {
        throw "Threshold governance policy/authority change requires explicit merge authority."
    }
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

$receiptEntries = New-Object System.Collections.Generic.List[object]
$receiptByCommit = @{}
foreach ($receiptPath in $receiptPaths) {
    $receipt = Get-Content $receiptPath.FullName -Raw | ConvertFrom-Json
    $repoReceiptPath = ConvertTo-RepoPath -Path $receiptPath.FullName
    $receiptEntry = @{ path = $repoReceiptPath; receipt = $receipt }
    $receiptEntries.Add($receiptEntry)
    if ($receipt.PSObject.Properties["commitHash"] -and $receipt.commitHash) {
        if (-not $receiptByCommit.ContainsKey([string] $receipt.commitHash)) {
            $receiptByCommit[[string] $receipt.commitHash] = New-Object System.Collections.Generic.List[object]
        }
        $receiptByCommit[[string] $receipt.commitHash].Add($receiptEntry)
    }
    elseif ($receipt.PSObject.Properties["sourceCommit"] -and $receipt.sourceCommit) {
        if (-not $receiptByCommit.ContainsKey([string] $receipt.sourceCommit)) {
            $receiptByCommit[[string] $receipt.sourceCommit] = New-Object System.Collections.Generic.List[object]
        }
        $receiptByCommit[[string] $receipt.sourceCommit].Add($receiptEntry)
    }
}

$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if (-not $state.invocationId) { throw "Lease state is missing invocationId." }
if (-not $state.currentHead) { throw "Lease state is missing currentHead." }
if (-not $state.remainingBudget) { throw "Lease state is missing remainingBudget." }

$prCommits = @(git rev-list --reverse "$resolvedBaseRefForGit..HEAD")
if ($prCommits.Count -eq 0 -and -not $preCommitWorktreeMode) { throw "No PR commits detected." }
$observedPrBaseHead = (& git rev-parse $resolvedBaseRefForGit 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$observedPrBaseHead)) {
    throw "Unable to resolve observed PR base head for BaseRef '$BaseRef'."
}
$observedPrBaseHead = [string]($observedPrBaseHead.Trim())
$effectiveReceiptPrBaseHead = $observedPrBaseHead
if ($governedEvidenceBasePromotionPr) {
    $resolvedExpectedBaseRefForGit = ConvertTo-OriginResolvedEvidenceRef -Ref $expectedBaseRef
    $evidenceBaseHead = (& git rev-parse $resolvedExpectedBaseRefForGit 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$evidenceBaseHead)) {
        throw "Unable to resolve evidence-base head for governed promotion '$expectedBaseRef'."
    }
    $evidenceBaseHead = [string]($evidenceBaseHead.Trim())
    if (-not (Test-ThresholdCommitIsAncestor -Ancestor $observedPrBaseHead -Descendant $evidenceBaseHead)) {
        throw "Governed evidence-base promotion does not descend from configured PR base. configuredBase=$BaseRef configuredBaseHead=$observedPrBaseHead evidenceBase=$expectedBaseRef evidenceBaseHead=$evidenceBaseHead"
    }
    if (-not (Test-ThresholdCommitIsAncestor -Ancestor $evidenceBaseHead -Descendant "HEAD")) {
        throw "Governed evidence-base promotion head does not include the reviewed evidence base. evidenceBase=$expectedBaseRef evidenceBaseHead=$evidenceBaseHead"
    }
    $effectiveReceiptPrBaseHead = $evidenceBaseHead
    Write-Host "governedEvidenceBasePromotionPr=true"
    Write-Host "configuredPrBaseHead=$observedPrBaseHead"
    Write-Host "evidenceReceiptPrBaseHead=$effectiveReceiptPrBaseHead"
}

$sourceCommitCount = 0
$productSourceCommits = New-Object System.Collections.Generic.List[string]
$sourceReceiptEntries = New-Object System.Collections.Generic.List[object]
foreach ($commit in $prCommits) {
    $commitPaths = @(git diff-tree --no-commit-id --name-only -r $commit)
    if ($commitPaths.Count -eq 0) { continue }

    $commitProductPaths = @($commitPaths | Where-Object { Test-ProductPath -Path $_ })
    if ($commitProductPaths.Count -gt 0) {
        $productSourceCommits.Add($commit)
    }

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
    $entriesForCommit = @()
    $isPromotionReconciledCommit = $false
    if (-not $receiptByCommit.ContainsKey($commit)) {
        if ($governedEvidenceBasePromotionPr) {
            $promotionReceiptEntries = @(Assert-PromotionSquashCommitCoveredByReceipts -Commit $commit -ReceiptEntries @($receiptEntries.ToArray()) -PromotionBaseHead $observedPrBaseHead)
            foreach ($promotionReceiptEntry in $promotionReceiptEntries) {
                $entriesForCommit += $promotionReceiptEntry
            }
            $isPromotionReconciledCommit = $true
        }
        else {
            throw "Source commit without corresponding Threshold receipt: $commit"
        }
    }
    else {
        $entriesForCommit = @($receiptByCommit[$commit].ToArray())
    }

    $entriesToValidate = @()
    if ($isPromotionReconciledCommit) {
        $entriesToValidate = @($entriesForCommit)
    }
    else {
        $h1bEntriesForCommit = @($entriesForCommit | Where-Object { $_.receipt.PSObject.Properties["candidateClass"] -and [string]$_.receipt.candidateClass -eq "industrial_refactoring_h1b" })
        if ($entriesForCommit.Count -gt 1) {
            if ($h1bEntriesForCommit.Count -gt 1) {
                throw "Multiple industrial_refactoring_h1b receipts found for source commit: $commit"
            }
            if ($h1bEntriesForCommit.Count -eq 0) {
                throw "Multiple competing receipts found for source commit: $commit"
            }
        }
        if ($h1bEntriesForCommit.Count -eq 1) {
            $entriesToValidate = @($h1bEntriesForCommit[0])
        }
        else {
            $entriesToValidate = @($entriesForCommit[0])
        }
    }

    foreach ($entry in $entriesToValidate) {
        $receipt = $entry.receipt
        if (-not $receipt.candidateId -and -not $receipt.batchId) { throw "Receipt is missing candidateId/batchId: $($entry.path)" }
        if (-not $receipt.baseHead) { throw "Receipt is missing baseHead: $($entry.path)" }
        if (-not $receipt.validation -or -not $receipt.validation.result) { throw "Receipt is missing validation result: $($entry.path)" }
        if (-not $receipt.nonClaims -or $receipt.nonClaims.Count -eq 0) { throw "Receipt is missing nonClaims: $($entry.path)" }
        $isCandidateReceipt = $receipt.PSObject.Properties["candidateId"] -and -not [string]::IsNullOrWhiteSpace([string]$receipt.candidateId)
        $hasProvenance = $receipt.PSObject.Properties["candidateClassProvenance"] -and $null -ne $receipt.candidateClassProvenance
        $receiptSourceCommit = Get-ThresholdReceiptSourceCommit -Receipt $receipt
        if ([string]::IsNullOrWhiteSpace([string]$receiptSourceCommit)) {
            $receiptSourceCommit = $commit
        }
        $receiptPrBaseHead = $effectiveReceiptPrBaseHead
        $sourceBaseHead = ""
        if ($isPromotionReconciledCommit) {
            $receiptParentHead = (& git rev-parse "$receiptSourceCommit^1" 2>$null)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$receiptParentHead)) {
                throw "Promotion receipt source parent unavailable receipt=$($entry.path) sourceCommit=$receiptSourceCommit"
            }
            $receiptParentHead = ([string]$receiptParentHead).Trim()
            if ([string]$receipt.baseHead -ne [string]$receiptParentHead) {
                throw "Promotion receipt baseHead mismatch receipt=$($entry.path) baseHead=$($receipt.baseHead) parentHead=$receiptParentHead"
            }
            if (-not (Test-ThresholdCommitIsAncestor -Ancestor $receiptParentHead -Descendant $effectiveReceiptPrBaseHead)) {
                throw "Promotion receipt source base is not ancestor of immutable PR base receipt=$($entry.path) receiptPrBaseHead=$effectiveReceiptPrBaseHead sourceBaseHead=$receiptParentHead"
            }
            $sourceBaseHead = $receiptParentHead
        }
        Write-Host "receiptPrBaseHead=$receiptPrBaseHead"
        if (-not [string]::IsNullOrWhiteSpace($sourceBaseHead)) {
            Write-Host "sourceBaseHead=$sourceBaseHead"
        }
        if ($isCandidateReceipt) {
            Assert-ThresholdCandidateClassProvenance -Receipt $receipt -ReceiptPath $entry.path -RequirePresent -PrBaseHead $receiptPrBaseHead
        }
        elseif ($hasProvenance) {
            Assert-ThresholdCandidateClassProvenance -Receipt $receipt -ReceiptPath $entry.path -PrBaseHead $receiptPrBaseHead
        }
        Assert-BatchCandidateDiscoveryEvidenceMatchesPrBase -Receipt $receipt -ReceiptPath $entry.path -PrBaseHead $receiptPrBaseHead
        Assert-BatchCandidateMutationsMatchSourceCommit -Receipt $receipt -ReceiptPath $entry.path -SourceCommit ([string]$receiptSourceCommit)
        Assert-ReceiptLeaseDigestMatchesReceiptCommit -ReceiptPath $entry.path -Receipt $receipt
        $changedFilesCommit = if ($isPromotionReconciledCommit) { [string]$receiptSourceCommit } else { [string]$commit }
        Assert-ChangedFilesMatchReceipt -Commit $changedFilesCommit -Receipt $receipt
        $sourceReceiptEntries.Add($entry)
    }
}

if ($sourceCommitCount -eq 0 -and $productPaths.Count -gt 0) {
    throw "No source commit detected in PR range."
}

if ($productPaths.Count -gt 0) {
    $prBody = $null
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_EVENT_PATH) -and (Test-Path $env:GITHUB_EVENT_PATH)) {
        $event = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
        if ($event.PSObject.Properties["pull_request"] -and $event.pull_request.PSObject.Properties["body"]) {
            $prBody = [string] $event.pull_request.body
        }
    }
    elseif ($null -ne $env:THRESHOLD_PR_BODY) {
        $prBody = [string] $env:THRESHOLD_PR_BODY
    }

    $expectedMetadataSourceCommits = @($productSourceCommits.ToArray())
    if ($governedEvidenceBasePromotionPr) {
        $expectedMetadataSourceCommits = @(
            $sourceReceiptEntries.ToArray() |
                ForEach-Object { Get-ThresholdReceiptSourceCommit -Receipt $_.receipt } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }
    $metadataBinding = Assert-ThresholdProductPrMetadataReceiptBinding `
        -Body $prBody `
        -SourceReceiptEntries @($sourceReceiptEntries.ToArray()) `
        -KnownCandidateClasses @(Get-ThresholdLeaseList -Lines $leaseLines -Name "allowedCandidateTypes") `
        -ExpectedSourceCommits @($expectedMetadataSourceCommits)
    Write-Host "thresholdPrH1BMetadataRequired=$($metadataBinding.h1bMetadataRequired.ToString().ToLowerInvariant())"
    if ($metadataBinding.h1bMetadataRequired) {
        Write-Host "thresholdPrMetadataEnvelopeDigest=$($metadataBinding.observedMetadataEnvelopeDigest)"
    }
}

Write-Host "sourceCommitReceiptCoverage=complete"
Write-Host "thresholdGovernanceLabelRequired=$($requiresMergeAuthority.ToString().ToLowerInvariant())"
Write-Host "thresholdMergeAuthorityRequired=$($requiresMergeAuthority.ToString().ToLowerInvariant())"
Write-Host "thresholdMergeAuthoritySatisfied=$($mergeAuthoritySatisfied.ToString().ToLowerInvariant())"
Write-Host "Threshold governance passed"
