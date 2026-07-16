[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [Parameter(Mandatory = $true)]
    [string] $CandidateId,
    [Parameter(Mandatory = $true)]
    [string] $CandidateClass,
    [Parameter(Mandatory = $true)]
    [string] $CommitMessage,
    [string[]] $AllowedPath = @(),
    [switch] $SkipMavenTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
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

if (-not (Test-Path $LeasePath)) { throw "Lease file not found: $LeasePath" }
if (-not (Test-Path $StatePath)) { throw "Lease state file not found: $StatePath. Run threshold/scripts/start-lease.ps1 first." }

$state = Get-Content $StatePath -Raw | ConvertFrom-Json
if ([int]$state.remainingBudget.candidates -le 0) { throw "No candidate budget remains in $StatePath." }
if ([int]$state.remainingBudget.commits -le 0) { throw "No commit budget remains in $StatePath." }

$changedPaths = @(& git diff --name-only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $changedPaths) {
    throw "No unstaged slice changes found."
}

if ($AllowedPath.Count -gt 0) {
    $runtimeAllowed = @(
        "threshold/lease-state/current-run.json"
    )
    $allowedNormalized = @(
        @($AllowedPath | ForEach-Object { ConvertTo-RepoPath $_ }) +
        @($runtimeAllowed | ForEach-Object { ConvertTo-RepoPath $_ })
    ) | Select-Object -Unique
    foreach ($path in $changedPaths) {
        if (-not ($allowedNormalized -contains (ConvertTo-RepoPath $path))) {
            throw "Changed path '$path' is not in explicit AllowedPath list."
        }
    }
}

$validateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "threshold/scripts/validate-slice.ps1", "-LeasePath", $LeasePath, "-StatePath", $StatePath)
if ($SkipMavenTest.IsPresent) { $validateArgs += "-SkipMavenTest" }
& powershell.exe @validateArgs
if ($LASTEXITCODE -ne 0) { throw "Threshold slice validation failed." }

$baseHead = (& git rev-parse HEAD).Trim()
foreach ($path in $changedPaths) {
    & git add -- $path
    if ($LASTEXITCODE -ne 0) { throw "Failed to stage changed path: $path" }
}

& git commit -m $CommitMessage
if ($LASTEXITCODE -ne 0) { throw "Source commit failed." }

$sourceCommit = (& git rev-parse HEAD).Trim()
$totals = Get-SurefireTotals
$validationResult = if ($SkipMavenTest.IsPresent) { "SKIPPED_BY_LEASE_INVOCATION" } else { "BUILD SUCCESS" }
$validationCommand = if ($SkipMavenTest.IsPresent) { "git diff --check" } else { ".\mvnw.cmd test" }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "threshold/scripts/record-receipt.ps1" `
    -LeasePath $LeasePath `
    -StatePath $StatePath `
    -CandidateId $CandidateId `
    -CandidateClass $CandidateClass `
    -BaseHead $baseHead `
    -CommitHash $sourceCommit `
    -DiffSummary $CommitMessage `
    -ValidationCommand $validationCommand `
    -ValidationResult $validationResult `
    -TestsRun $totals.testsRun `
    -Failures $totals.failures `
    -Errors $totals.errors `
    -Skipped $totals.skipped `
    -ReceiptMaterialization "post-commit" `
    -PerCommitValidationLogAvailable `
    -UpdateState
if ($LASTEXITCODE -ne 0) { throw "Receipt recording failed for source commit $sourceCommit." }

$trackedReceiptChanges = @(& git diff --name-only | Where-Object { $_ -like "threshold/receipts/*" -or $_ -eq "threshold/lease-state/current-run.json" })
$untrackedReceiptChanges = @(& git ls-files --others --exclude-standard threshold/receipts | Where-Object { $_ -like "threshold/receipts/*" })
$receiptChanges = @($trackedReceiptChanges + $untrackedReceiptChanges | Select-Object -Unique)
if (-not $receiptChanges) {
    throw "Receipt recording produced no receipt/state changes."
}

foreach ($path in $receiptChanges) {
    & git add -- $path
    if ($LASTEXITCODE -ne 0) { throw "Failed to stage receipt path: $path" }
}

& git commit -m "Record Threshold receipt for $CandidateId"
if ($LASTEXITCODE -ne 0) { throw "Receipt commit failed." }

$finalStatus = @(& git status --porcelain)
if ($finalStatus) {
    throw "Worktree is not clean after receipt commit."
}

$receiptCommit = (& git rev-parse HEAD).Trim()
Write-Host "Threshold slice completed"
Write-Host "candidateId=$CandidateId"
Write-Host "sourceCommit=$sourceCommit"
Write-Host "receiptCommit=$receiptCommit"
Write-Host "baseHead=$baseHead"
