[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [int] $MinScore = 70,
    [int] $MaxSlicesPerBatch = 3,
    [int] $MaxFilesPerBatch = 3,
    [int] $MaxChangedLinesPerBatch = 120,
    [string] $CandidatePocketPath = "",
    [string] $PrBaseHead = "",
    [string] $DiscoveryEvidenceRoot = "threshold/discovery-evidence",
    [switch] $RequirePreProductDiscoveryEvidence,
    [switch] $SkipMavenTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function Get-LineEnding {
    param([string] $Content)
    if ($Content.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Write-TextFile {
    param([string] $Path, [string] $Content)
    $encoding = New-Object System.Text.UTF8Encoding $false
    $normalizedContent = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $normalizedContent, $encoding)
}

function Get-FileSha256 {
    param([string] $Path)
    if (-not (Test-Path $Path)) { throw "File not found for hashing: $Path" }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-GitBlobSha256 {
    param([string] $Revision, [string] $Path)

    $repoPath = ConvertTo-RepoPath $Path
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git cat-file -e "$Revision`:$repoPath" 2>$null
    $exists = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previousErrorActionPreference
    if (-not $exists) {
        throw "Git blob not found for hashing: $Revision`:$repoPath"
    }

    $spec = "$Revision`:$repoPath"
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
            throw "Failed to hash git blob: $spec. $stderr"
        }
        return ([System.BitConverter]::ToString($sha256.Hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $process.Dispose()
    }
}

function Assert-CleanWorktree {
    $status = @(& git status --porcelain)
    if ($status) {
        throw "Worktree is not clean. run-next-batch requires a clean start."
    }
}

function Get-SurefireTotals {
    $totals = [ordered]@{ testsRun = 0; failures = 0; errors = 0; skipped = 0 }
    $reports = @(Get-ChildItem "target/surefire-reports" -Filter "*.xml" -ErrorAction SilentlyContinue)
    foreach ($report in $reports) {
        [xml]$xml = Get-Content $report.FullName
        $suite = $xml.testsuite
        if ($suite) {
            $totals.testsRun += [int]$suite.tests
            $totals.failures += [int]$suite.failures
            $totals.errors += [int]$suite.errors
            $totals.skipped += [int]$suite.skipped
        }
    }
    return $totals
}

function Get-LeaseState {
    if (-not (Test-Path $StatePath)) { throw "Lease state file not found: $StatePath" }
    return Get-Content $StatePath -Raw | ConvertFrom-Json
}

function Get-LeaseIntScalarOrDefault {
    param(
        [string[]] $Lines,
        [string] $Name,
        [int] $DefaultValue
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) {
        return $DefaultValue
    }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "")
}

function Get-CommentWrapThreshold {
    if (-not (Test-Path $LeasePath)) {
        return 120
    }
    $leaseLines = @(Get-Content $LeasePath)
    return Get-LeaseIntScalarOrDefault -Lines $leaseLines -Name "commentWrapThreshold" -DefaultValue 120
}

function Get-ApprovedBatchClasses {
    if (-not (Test-Path $GatePath)) { throw "Batch gate file not found: $GatePath" }
    $gate = Get-Content $GatePath -Raw | ConvertFrom-Json
    if (-not $gate.batchReceiptMode -or $gate.batchReceiptMode.enabled -ne $true) {
        throw "Batch receipt mode is not enabled in $GatePath."
    }
    return @($gate.batchReceiptMode.approvedCandidateClasses | ForEach-Object { [string]$_.candidateClass })
}

function Get-SupportedBatchClasses {
    return @("comment_wrap_cleanup")
}

function Find-ConservativeCommentSplitPoint {
    param([string] $Text)

    $minimumPrefix = 24
    $preferredMaxIndex = [Math]::Min(112, $Text.Length - 1)
    if ($preferredMaxIndex -lt $minimumPrefix) { return $null }

    $spaceSplit = $Text.LastIndexOf(" ", $preferredMaxIndex)
    if ($spaceSplit -ge $minimumPrefix -and $spaceSplit -lt ($Text.Length - 1)) {
        return [pscustomobject]@{ Index = $spaceSplit; KeepDelimiter = $false }
    }

    foreach ($delimiter in @("/", "#", "?", "&", "-", ".", ":")) {
        $splitIndex = $Text.LastIndexOf($delimiter, $preferredMaxIndex)
        if ($splitIndex -ge $minimumPrefix -and $splitIndex -lt ($Text.Length - 1)) {
            return [pscustomobject]@{ Index = $splitIndex; KeepDelimiter = $true }
        }
    }

    return $null
}

function Test-BatchJavadocCommentLine {
    param(
        [string[]] $Lines,
        [int] $Index,
        [hashtable] $JavaTextBlockLineState = @{}
    )

    if ($Index -lt 0 -or $Index -ge $Lines.Count) {
        return $false
    }
    if ($JavaTextBlockLineState.ContainsKey($Index + 1)) {
        return $false
    }

    $insideJavadoc = $false
    for ($i = 0; $i -le $Index; $i++) {
        if ($JavaTextBlockLineState.ContainsKey($i + 1)) {
            continue
        }
        $line = [string]$Lines[$i]
        if (-not $insideJavadoc -and $line -match '^\s*/\*\*') {
            $insideJavadoc = $true
        }
        if ($i -eq $Index) {
            return $insideJavadoc
        }
        if ($insideJavadoc -and $line -match '\*/') {
            $insideJavadoc = $false
        }
    }

    return $false
}

function Apply-CommentWrapCleanup {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { throw "Candidate file not found: $path" }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) {
        throw "Comment wrap cleanup requires a line marker candidate."
    }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "Candidate line '$lineNumber' is outside file range in $path."
    }
    $javaTextBlockLineState = Get-ThresholdJavaTextBlockLineState -Lines $lines
    if (-not (Test-BatchJavadocCommentLine -Lines $lines -Index ($lineNumber - 1) -JavaTextBlockLineState $javaTextBlockLineState)) {
        throw "Line '$lineNumber' is not inside a current Javadoc context in $path."
    }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*\*\s+)(?<text>\S.*)$')
    if (-not $match.Success -or $line.Length -le (Get-CommentWrapThreshold)) {
        throw "Line '$lineNumber' is not a supported long comment line in $path."
    }

    $indent = $match.Groups["indent"].Value
    $text = $match.Groups["text"].Value.Trim()
    $splitPoint = Find-ConservativeCommentSplitPoint -Text $text
    if (-not $splitPoint) {
        throw "Could not find a conservative split point for comment line '$lineNumber'."
    }

    $splitIndex = [int]$splitPoint.Index
    $firstSegment = if ([bool]$splitPoint.KeepDelimiter) {
        $text.Substring(0, $splitIndex + 1).TrimEnd()
    }
    else {
        $text.Substring(0, $splitIndex).TrimEnd()
    }
    $secondSegment = $text.Substring($splitIndex + 1).TrimStart()

    $updatedLines = @()
    if ($lineNumber -gt 1) { $updatedLines += $lines[0..($lineNumber - 2)] }
    $updatedLines += @("$indent$firstSegment", "$indent$secondSegment")
    if ($lineNumber -lt $lines.Count) { $updatedLines += $lines[$lineNumber..($lines.Count - 1)] }

    $originalText = Get-Content $path -Raw
    $updatedText = $updatedLines -join (Get-LineEnding -Content $originalText)
    Write-TextFile -Path $path -Content $updatedText
}

function Test-CommentWrapCandidateApplies {
    param([pscustomobject] $Candidate)

    $path = ConvertTo-RepoPath $Candidate.file
    if (-not (Test-Path $path)) { return $false }

    $member = [string]$Candidate.member
    if (-not $member.StartsWith("line-")) { return $false }

    $lineNumber = [int]($member.Substring(5))
    $lines = Get-Content $path
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) { return $false }
    $javaTextBlockLineState = Get-ThresholdJavaTextBlockLineState -Lines $lines
    if (-not (Test-BatchJavadocCommentLine -Lines $lines -Index ($lineNumber - 1) -JavaTextBlockLineState $javaTextBlockLineState)) { return $false }

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*\*\s+)(?<text>\S.*)$')
    if (-not $match.Success -or $line.Length -le (Get-CommentWrapThreshold)) { return $false }

    $text = $match.Groups["text"].Value.Trim()
    return $null -ne (Find-ConservativeCommentSplitPoint -Text $text)
}

function Invoke-DiscoveryCanary {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-discovery-canary.ps1" `
        -LeasePath $LeasePath `
        -GatePath $GatePath
    if ($LASTEXITCODE -ne 0) { throw "Threshold discovery canary failed." }
}

function New-CandidatePocket {
    if (-not [string]::IsNullOrWhiteSpace($CandidatePocketPath)) {
        if (-not (Test-Path $CandidatePocketPath)) {
            throw "Prepared candidate pocket not found for batch execution: $CandidatePocketPath"
        }
        return $CandidatePocketPath
    }

    throw "Batch execution requires a prepared candidate pocket with pre-product discovery evidence before mutation."
}

function Get-BatchCandidates {
    param(
        [string] $PocketPath,
        [string[]] $ApprovedBatchClasses,
        [string[]] $ProcessedCandidateIds = @()
    )

    $pocket = Get-Content $PocketPath -Raw | ConvertFrom-Json
    $eligible = @(
        $pocket.candidates |
            Where-Object {
                [int]$_.score -ge $MinScore -and
                $_.autoPatchable -eq $true -and
                ($ProcessedCandidateIds -notcontains [string]$_.candidateId) -and
                $ApprovedBatchClasses -contains [string]$_.candidateClass
            }
    )
    if (-not $eligible) {
        Write-Host "ready_no_batchable_candidates_verified"
        Write-Host "candidateCount=$(@($pocket.candidates).Count)"
        return @()
    }

    $firstClass = [string]$eligible[0].candidateClass
    $sameClass = @($eligible | Where-Object { [string]$_.candidateClass -eq $firstClass })
    $selected = @()
    $selectedFiles = @()
    $processedCandidatePaths = New-Object System.Collections.Generic.HashSet[string]
    foreach ($candidate in @($pocket.candidates)) {
        $candidateId = [string]$candidate.candidateId
        if ($ProcessedCandidateIds -notcontains $candidateId) {
            continue
        }
        if ($candidate.PSObject.Properties["file"] -and $candidate.file) {
            [void]$processedCandidatePaths.Add((ConvertTo-RepoPath $candidate.file))
        }
    }

    foreach ($candidate in $sameClass) {
        $path = ConvertTo-RepoPath $candidate.file
        if (-not (Test-Path $path)) { continue }
        $candidateId = [string]$candidate.candidateId
        $candidateMember = if ($candidate.PSObject.Properties["member"]) { [string]$candidate.member } else { "" }
        if ($ProcessedCandidateIds.Count -gt 0 -and $candidateMember.StartsWith("line-")) {
            if ($processedCandidatePaths.Count -eq 0) {
                Write-Host "candidateSkippedReason=line_rebinding_required_after_prior_line_mutation_unknown_scope:$candidateId"
                continue
            }
            if ($processedCandidatePaths.Contains($path)) {
                Write-Host "candidateSkippedReason=line_rebinding_required_after_prior_line_mutation:$candidateId"
                continue
            }
        }
        if ([string]$candidate.candidateClass -eq "comment_wrap_cleanup" -and
            -not (Test-CommentWrapCandidateApplies -Candidate $candidate)) {
            Write-Host "skippedStaleCandidate=$($candidate.candidateId)"
            continue
        }
        if ($selectedFiles -notcontains $path) {
            $selectedFiles += $path
        }
        if (@($selectedFiles).Count -gt $MaxFilesPerBatch) { break }
        $selected += $candidate
        if ($selected.Count -ge $MaxSlicesPerBatch) { break }
    }

    return $selected
}

function Assert-BatchCandidateHasPreProductDiscoveryEvidence {
    param(
        [pscustomobject] $Candidate,
        [string] $PocketPath,
        [string] $ObservedPrBaseHead
    )

    if ([string]::IsNullOrWhiteSpace($ObservedPrBaseHead)) {
        throw "Batch execution requires PrBaseHead with pre-product discovery evidence before mutation."
    }

    $pocket = Get-Content $PocketPath -Raw | ConvertFrom-Json
    $discoverySourceHead = [string](Get-ThresholdJsonProperty $pocket "preProductDiscoverySourceHead" "")
    if ([string]::IsNullOrWhiteSpace($discoverySourceHead)) {
        $discoverySourceHead = [string](Get-ThresholdJsonProperty $pocket "generatedFromHead" "")
    }
    if ([string]::IsNullOrWhiteSpace($discoverySourceHead)) {
        throw "Prepared candidate pocket is missing discovery source head for batch execution."
    }
    if (-not (Test-ThresholdCommitIsAncestor -Ancestor $discoverySourceHead -Descendant $ObservedPrBaseHead)) {
        throw "Batch discovery source head is not an ancestor of PR base head. source=$discoverySourceHead prBase=$ObservedPrBaseHead"
    }

    $candidateId = [string]$Candidate.candidateId
    $evidencePath = Get-ThresholdCandidateDiscoveryEvidencePath -DiscoveryEvidenceRoot $DiscoveryEvidenceRoot -CandidateId $candidateId -BaseHead $discoverySourceHead
    $evidenceAtPrBase = Get-ThresholdCandidateDiscoveryEvidenceFromRevision -Revision $ObservedPrBaseHead -Path $evidencePath
    if ($null -eq $evidenceAtPrBase) {
        throw "Pre-product discovery evidence is required before batch execution. candidateId=$candidateId path=$evidencePath prBase=$ObservedPrBaseHead"
    }
    $evidenceDigest = Get-ThresholdCandidateDiscoveryEvidenceDigest -DiscoveryEvidence $evidenceAtPrBase
    if ([string]$evidenceDigest -ne [string](Get-ThresholdJsonProperty $evidenceAtPrBase "discoveryEvidenceDigest" "")) {
        throw "Pre-product discovery evidence digest mismatch before batch execution. candidateId=$candidateId path=$evidencePath"
    }

    foreach ($field in @("candidateId", "candidateClass")) {
        if ([string](Get-ThresholdJsonProperty $evidenceAtPrBase $field "") -ne [string](Get-ThresholdJsonProperty $Candidate $field "")) {
            throw "Pre-product discovery evidence candidate $field mismatch before batch execution. candidateId=$candidateId path=$evidencePath"
        }
    }
    if ([string](Get-ThresholdJsonProperty $evidenceAtPrBase "candidatePath" "") -ne [string](ConvertTo-RepoPath $Candidate.file)) {
        throw "Pre-product discovery evidence candidatePath mismatch before batch execution. candidateId=$candidateId path=$evidencePath"
    }
    if ([string](Get-ThresholdJsonProperty $evidenceAtPrBase "candidateMember" "") -ne [string]$Candidate.member) {
        throw "Pre-product discovery evidence candidateMember mismatch before batch execution. candidateId=$candidateId path=$evidencePath"
    }

    return [ordered]@{
        discoveryEvidencePath = ConvertTo-RepoPath $evidencePath
        discoveryEvidenceDigest = $evidenceDigest
        discoverySourceHead = $discoverySourceHead
        prBaseHead = $ObservedPrBaseHead
        immutableDiscoveryEvidencePresent = $true
    }
}

function Get-ChangedLineCount {
    $numstat = @(& git diff --numstat)
    $count = 0
    foreach ($line in $numstat) {
        $parts = $line -split "\s+"
        if ($parts.Count -ge 2) {
            if ($parts[0] -match "^\d+$") { $count += [int]$parts[0] }
            if ($parts[1] -match "^\d+$") { $count += [int]$parts[1] }
        }
    }
    return $count
}

function Revert-BatchChanges {
    $paths = @(& git diff --name-only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($path in $paths) {
        & git restore -- $path
        if ($LASTEXITCODE -ne 0) { throw "Failed to restore batch path: $path" }
    }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/sync-lease-state.ps1" `
    -LeasePath $LeasePath `
    -StatePath $StatePath `
    -CheckOnly
if ($LASTEXITCODE -ne 0) { throw "Threshold lease-state check failed before batch." }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/preflight.ps1" -LeasePath $LeasePath
if ($LASTEXITCODE -ne 0) { throw "Threshold preflight failed before batch." }

Assert-CleanWorktree
$state = Get-LeaseState
if ([int]$state.remainingBudget.candidates -le 0 -or [int]$state.remainingBudget.commits -le 0) {
    throw "No batch budget remains in $StatePath."
}

$approvedBatchClasses = @(Get-ApprovedBatchClasses | Where-Object { (Get-SupportedBatchClasses) -contains $_ })
if (-not $approvedBatchClasses) {
    Write-Host "ready_no_supported_batch_classes_verified"
    exit 0
}
Invoke-DiscoveryCanary
Write-Host "batchPreProductDiscoveryEvidenceRequired=true"
Write-Host "batchPreProductDiscoveryEvidencePolicy=all batch executions require prepared discovery evidence before file mutation"
$pocketPath = New-CandidatePocket
$processedCandidateIds = @()
if ($state.PSObject.Properties.Name -contains "processedCandidateIds") {
    $processedCandidateIds = @($state.processedCandidateIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$candidates = @(Get-BatchCandidates -PocketPath $pocketPath -ApprovedBatchClasses $approvedBatchClasses -ProcessedCandidateIds $processedCandidateIds)
if (-not $candidates -or $candidates.Count -eq 0) {
    exit 0
}

$allowedCandidateBudget = [Math]::Min([int]$state.remainingBudget.candidates, $MaxSlicesPerBatch)
if ($candidates.Count -gt $allowedCandidateBudget) {
    $candidates = @($candidates | Select-Object -First $allowedCandidateBudget)
}

$candidateDiscoveryEvidenceById = @{}
foreach ($candidate in $candidates) {
    $candidateId = [string]$candidate.candidateId
    if ([string]::IsNullOrWhiteSpace($candidateId)) {
        throw "Batch candidate is missing candidateId before mutation."
    }
    if ($candidateDiscoveryEvidenceById.ContainsKey($candidateId)) {
        throw "Duplicate batch candidateId before mutation: $candidateId"
    }
    $candidateDiscoveryEvidenceById[$candidateId] = Assert-BatchCandidateHasPreProductDiscoveryEvidence `
        -Candidate $candidate `
        -PocketPath $pocketPath `
        -ObservedPrBaseHead $PrBaseHead
}

$baseHead = (& git rev-parse HEAD).Trim()
$batchId = "threshold-batch-$($baseHead.Substring(0, 12))-$((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))"
$candidateReceipts = New-Object System.Collections.Generic.List[object]

try {
    foreach ($candidate in $candidates) {
        $candidateId = [string]$candidate.candidateId
        $candidateClass = [string]$candidate.candidateClass
        if ($candidateClass -ne "comment_wrap_cleanup") {
            throw "Batch executor does not support candidate class '$candidateClass'."
        }

        $candidateDiscoveryEvidence = $candidateDiscoveryEvidenceById[$candidateId]

        $path = ConvertTo-RepoPath $candidate.file
        $beforeHash = Get-FileSha256 -Path $path
        Apply-CommentWrapCleanup -Candidate $candidate
        $afterHash = Get-FileSha256 -Path $path
        if ($beforeHash -eq $afterHash) {
            throw "Candidate '$($candidate.candidateId)' produced no materialized file change."
        }

        $candidateReceipts.Add([ordered]@{
            candidateId = $candidateId
            candidateClass = $candidateClass
            file = $path
            member = [string]$candidate.member
            beforeSha256 = $beforeHash
            afterSha256 = $afterHash
            expectedDiffSummary = [string]$candidate.expectedDiffSummary
            gateApproved = $true
            executionMode = "batched_auto_patchable"
            candidateDiscoveryEvidence = $candidateDiscoveryEvidence
        }) | Out-Null
    }

    $changedPaths = @(& git diff --name-only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $changedPaths) { throw "Batch produced no changed paths." }
    if ($changedPaths.Count -gt $MaxFilesPerBatch) {
        throw "Batch changed $($changedPaths.Count) files, exceeding maxFilesPerBatch=$MaxFilesPerBatch."
    }
    $changedLineCount = Get-ChangedLineCount
    if ($changedLineCount -gt $MaxChangedLinesPerBatch) {
        throw "Batch changed $changedLineCount lines, exceeding maxChangedLinesPerBatch=$MaxChangedLinesPerBatch."
    }

    & git diff --check
    if ($LASTEXITCODE -ne 0) { throw "git diff --check failed for batch." }

    if (-not $SkipMavenTest.IsPresent) {
        $env:JAVA_HOME = "C:\Program Files\Java\jdk-17"
        & .\mvnw.cmd test
        if ($LASTEXITCODE -ne 0) { throw "Maven test failed for batch." }
    }

    foreach ($path in $changedPaths) {
        & git add -- $path
        if ($LASTEXITCODE -ne 0) { throw "Failed to stage batch path: $path" }
    }

    $batchClass = [string]$candidateReceipts[0].candidateClass
    & git commit -m "Refactor PetClinic $batchClass batch"
    if ($LASTEXITCODE -ne 0) { throw "Batch source commit failed." }
    $sourceCommit = (& git rev-parse HEAD).Trim()

    $totals = Get-SurefireTotals
    $receipt = [ordered]@{
        schemaVersion = "threshold.petclinic.batch-receipt.v0.1"
        batchId = $batchId
        leaseId = [string]$state.leaseId
        leaseDigest = Get-GitBlobSha256 -Revision "HEAD" -Path $LeasePath
        branch = [string]$state.branch
        baseHead = $baseHead
        sourceCommit = $sourceCommit
        candidateClass = $batchClass
        candidateCount = $candidateReceipts.Count
        changedFiles = @($changedPaths | ForEach-Object { ConvertTo-RepoPath $_ })
        changedLineCount = $changedLineCount
        candidates = @($candidateReceipts)
        validation = [ordered]@{
            discoveryCanary = "passed"
            diffCheck = "passed"
            command = if ($SkipMavenTest.IsPresent) { "git diff --check" } else { ".\mvnw.cmd test" }
            result = if ($SkipMavenTest.IsPresent) { "SKIPPED_BY_LEASE_INVOCATION" } else { "BUILD SUCCESS" }
            testsRun = $totals.testsRun
            failures = $totals.failures
            errors = $totals.errors
            skipped = $totals.skipped
        }
        nonClaims = @(
            "batch receipt preserves per-candidate evidence but is not an external review claim",
            "no upstream interaction in batch slice",
            "no PR update in batch slice",
            "no merge, release, or deploy in batch slice",
            "no public readiness, correctness, security, or compliance claim"
        )
    }

    $receiptDir = "threshold/receipts"
    if (-not (Test-Path $receiptDir)) { New-Item -ItemType Directory -Path $receiptDir | Out-Null }
    $receiptPath = Join-Path $receiptDir "$batchId.json"
    $receipt | ConvertTo-Json -Depth 12 | Set-Content $receiptPath

    $remainingCandidates = [Math]::Max(0, [int]$state.remainingBudget.candidates - $candidateReceipts.Count)
    $remainingCommits = [Math]::Max(0, [int]$state.remainingBudget.commits - 1)
    $state.currentHead = $sourceCommit
    $state.currentSourceHead = $sourceCommit
    $state.candidatesProcessed = [int]$state.candidatesProcessed + $candidateReceipts.Count
    foreach ($candidateReceipt in $candidateReceipts) {
        $processedId = [string]$candidateReceipt.candidateId
        if (-not [string]::IsNullOrWhiteSpace($processedId) -and $processedCandidateIds -notcontains $processedId) {
            $processedCandidateIds += $processedId
        }
    }
    $state | Add-Member -NotePropertyName "processedCandidateIds" -NotePropertyValue @($processedCandidateIds) -Force
    $state.commitsCreated = [int]$state.commitsCreated + 1
    $state.remainingBudget.candidates = $remainingCandidates
    $state.remainingBudget.commits = $remainingCommits
    $state.lastReceipt = ConvertTo-RepoPath $receiptPath
    if ($remainingCandidates -eq 0 -or $remainingCommits -eq 0) {
        $state.terminalState = "budget_exhausted_verified"
        if ($state.PSObject.Properties["terminalReason"]) {
            $state.terminalReason = "remaining candidate or commit budget is exhausted after batch validation passed"
        }
        else {
            $state | Add-Member -NotePropertyName "terminalReason" -NotePropertyValue "remaining candidate or commit budget is exhausted after batch validation passed"
        }
    }
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $StatePath

    & git add -- $receiptPath $StatePath
    if ($LASTEXITCODE -ne 0) { throw "Failed to stage batch receipt/state." }
    & git commit -m "Record Threshold batch receipt for $batchClass"
    if ($LASTEXITCODE -ne 0) { throw "Batch receipt commit failed." }

    $finalStatus = @(& git status --porcelain)
    if ($finalStatus) { throw "Worktree is not clean after batch receipt commit." }

    Write-Host "Threshold batch completed"
    Write-Host "batchId=$batchId"
    Write-Host "candidateClass=$batchClass"
    Write-Host "candidateCount=$($candidateReceipts.Count)"
    Write-Host "sourceCommit=$sourceCommit"
    Write-Host "receiptPath=$(ConvertTo-RepoPath $receiptPath)"
}
catch {
    Revert-BatchChanges
    throw
}
