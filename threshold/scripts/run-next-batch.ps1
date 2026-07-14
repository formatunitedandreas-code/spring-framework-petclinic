[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [int] $MinScore = 70,
    [int] $MaxSlicesPerBatch = 3,
    [int] $MaxFilesPerBatch = 3,
    [int] $MaxChangedLinesPerBatch = 120,
    [switch] $SkipMavenTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-ApprovedBatchClasses {
    if (-not (Test-Path $GatePath)) { throw "Batch gate file not found: $GatePath" }
    $gate = Get-Content $GatePath -Raw | ConvertFrom-Json
    if (-not $gate.batchReceiptMode -or $gate.batchReceiptMode.enabled -ne $true) {
        throw "Batch receipt mode is not enabled in $GatePath."
    }
    return @($gate.batchReceiptMode.approvedCandidateClasses | ForEach-Object { [string]$_.candidateClass })
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

    $line = $lines[$lineNumber - 1]
    $match = [regex]::Match($line, '^(?<indent>\s*\*\s+)(?<text>\S.*)$')
    if (-not $match.Success -or $line.Length -le 120) {
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

function Invoke-DiscoveryCanary {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/test-discovery-canary.ps1" `
        -LeasePath $LeasePath `
        -GatePath $GatePath
    if ($LASTEXITCODE -ne 0) { throw "Threshold discovery canary failed." }
}

function New-CandidatePocket {
    $head = (& git rev-parse HEAD).Trim()
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "threshold-batch-candidate-pocket-$head.json"
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }

    $discoveryOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/discover-candidates.ps1" `
        -LeasePath $LeasePath `
        -GatePath $GatePath `
        -PocketPath $path `
        -Limit 100)
    if ($LASTEXITCODE -ne 0) { throw "Candidate discovery failed." }
    foreach ($line in $discoveryOutput) {
        Write-Host $line
    }
    if (-not (Test-Path $path)) { throw "Candidate discovery produced no pocket." }
    return $path
}

function Get-BatchCandidates {
    param(
        [string] $PocketPath,
        [string[]] $ApprovedBatchClasses
    )

    $pocket = Get-Content $PocketPath -Raw | ConvertFrom-Json
    $eligible = @(
        $pocket.candidates |
            Where-Object {
                [int]$_.score -ge $MinScore -and
                $_.autoPatchable -eq $true -and
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
    $selected = New-Object System.Collections.Generic.List[object]
    $selectedFiles = New-Object System.Collections.Generic.HashSet[string]

    foreach ($candidate in $sameClass) {
        $path = ConvertTo-RepoPath $candidate.file
        if (-not (Test-Path $path)) { continue }
        [void]$selectedFiles.Add($path)
        if ($selectedFiles.Count -gt $MaxFilesPerBatch) { break }
        $selected.Add($candidate) | Out-Null
        if ($selected.Count -ge $MaxSlicesPerBatch) { break }
    }

    return @($selected)
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

$approvedBatchClasses = Get-ApprovedBatchClasses
Invoke-DiscoveryCanary
$pocketPath = New-CandidatePocket
$candidates = @(Get-BatchCandidates -PocketPath $pocketPath -ApprovedBatchClasses $approvedBatchClasses)
if (-not $candidates -or $candidates.Count -eq 0) {
    exit 0
}

$allowedCandidateBudget = [Math]::Min([int]$state.remainingBudget.candidates, $MaxSlicesPerBatch)
if ($candidates.Count -gt $allowedCandidateBudget) {
    $candidates = @($candidates | Select-Object -First $allowedCandidateBudget)
}

$baseHead = (& git rev-parse HEAD).Trim()
$batchId = "threshold-batch-$($baseHead.Substring(0, 12))-$((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))"
$candidateReceipts = New-Object System.Collections.Generic.List[object]

try {
    foreach ($candidate in $candidates) {
        $candidateClass = [string]$candidate.candidateClass
        if ($candidateClass -ne "comment_wrap_cleanup") {
            throw "Batch executor does not support candidate class '$candidateClass'."
        }

        $path = ConvertTo-RepoPath $candidate.file
        $beforeHash = Get-FileSha256 -Path $path
        Apply-CommentWrapCleanup -Candidate $candidate
        $afterHash = Get-FileSha256 -Path $path
        if ($beforeHash -eq $afterHash) {
            throw "Candidate '$($candidate.candidateId)' produced no materialized file change."
        }

        $candidateReceipts.Add([ordered]@{
            candidateId = [string]$candidate.candidateId
            candidateClass = $candidateClass
            file = $path
            member = [string]$candidate.member
            beforeSha256 = $beforeHash
            afterSha256 = $afterHash
            expectedDiffSummary = [string]$candidate.expectedDiffSummary
            gateApproved = $true
            executionMode = "batched_auto_patchable"
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
    $state.commitsCreated = [int]$state.commitsCreated + 1
    $state.remainingBudget.candidates = $remainingCandidates
    $state.remainingBudget.commits = $remainingCommits
    $state.lastReceipt = ConvertTo-RepoPath $receiptPath
    if ($remainingCandidates -eq 0 -or $remainingCommits -eq 0) {
        $state.terminalState = "budget_exhausted"
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
