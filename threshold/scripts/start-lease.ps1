[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $StatePath = "threshold/lease-state/current-run.json",
    [string] $LeaseName = "petclinic-threshold-governed-refactor-lease-v1",
    [string] $Mode = "local_refactor",
    [int] $MaxCandidatesThisRun = 5,
    [int] $MaxCommitsThisRun = 5,
    [int] $MaxFilesPerCandidate = 1,
    [int] $MaxChangedLinesPerCandidate = 80,
    [int] $MaxRepairAttemptsPerCandidate = 1,
    [switch] $DraftPrAllowed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

$branch = (& git branch --show-current).Trim()
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw "Unable to determine current git branch."
}

$head = (& git rev-parse HEAD).Trim()
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$invocationId = "$LeaseName-$timestamp"

$leaseDir = Split-Path $LeasePath -Parent
if ($leaseDir -and -not (Test-Path $leaseDir)) {
    New-Item -ItemType Directory -Path $leaseDir | Out-Null
}

$stateDir = Split-Path $StatePath -Parent
if ($stateDir -and -not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

$draftPrValue = if ($DraftPrAllowed.IsPresent) { "true" } else { "false" }

$lease = @"
leaseName: $LeaseName
repository: $((Get-Location).Path)
branch: $branch
baseRemote: origin
baseRef: origin/main
startHead: $head
headPolicy: descendantOfStartHead
scopeExpansionTier: 0
longLineThreshold: 120
commentWrapThreshold: 120
springDataQueryThreshold: 80
repositoryMethodLengthThreshold: 8
utilityMethodLengthThreshold: 8

budget:
  maxCandidatesThisRun: $MaxCandidatesThisRun
  maxCommitsThisRun: $MaxCommitsThisRun
  maxFilesPerCandidate: $MaxFilesPerCandidate
  maxGovernanceFilesPerCandidate: 8
  maxChangedLinesPerCandidate: $MaxChangedLinesPerCandidate
  maxGovernanceChangedLinesPerCandidate: 1200
  maxRepairAttemptsPerCandidate: $MaxRepairAttemptsPerCandidate

allowedRiskClasses:
  - R0_READ_ONLY
  - R1_READOUT
  - R2_REVERSIBLE_LOCAL_MUTATION
  - R3_LOCAL_COMMIT
  - R4_OWNED_REPO_BRANCH_PUSH
  - R4_OWNED_REPO_DRAFT_PR_UPDATE

allowedPaths:
  - src/main/java/org/springframework/samples/petclinic/service/*.java
  - src/main/java/org/springframework/samples/petclinic/service/**/*.java
  - src/main/java/org/springframework/samples/petclinic/web/*.java
  - src/main/java/org/springframework/samples/petclinic/web/**/*.java
  - src/main/java/org/springframework/samples/petclinic/repository/*.java
  - src/main/java/org/springframework/samples/petclinic/repository/**/*.java
  - src/main/java/org/springframework/samples/petclinic/model/*.java
  - src/main/java/org/springframework/samples/petclinic/model/**/*.java
  - src/main/java/org/springframework/samples/petclinic/util/*.java
  - src/main/java/org/springframework/samples/petclinic/util/**/*.java
  - src/main/java/org/springframework/samples/petclinic/*.java
  - threshold/leases/*.yaml
  - threshold/receipts/*.json
  - threshold/lease-state/*.json
  - threshold/candidate-pocket/*.json
  - threshold/discovery-canaries/**/*.java
  - threshold/discovery-canaries/*.json
  - threshold/gates/*.json
  - threshold/lanes/*.yaml
  - threshold/scripts/*.ps1
  - .github/workflows/threshold-governance.yml

forbiddenPaths:
  - pom.xml
  - src/main/resources/**
  - src/test/**
  - target/**
  - .github/dependabot.yml

allowedCandidateTypes:
  - private_helper_extraction_for_readability
  - redundant_local_variable_simplification
  - duplicate_literal_local_constant_extraction
  - controller_branch_readability_decomposition
  - method_signature_wrap_cleanup
  - repository_readability_cleanup
  - spring_data_query_wrap_cleanup
  - spring_data_query_concat_wrap_cleanup
  - model_readability_cleanup
  - split_string_constant_normalization
  - string_constant_wrap_cleanup
  - utility_readability_cleanup
  - application_bootstrap_readability_cleanup
  - leading_tab_indentation_cleanup
  - comment_wrap_cleanup
  - line_comment_wrap_cleanup
  - method_spacing_normalization
  - threshold_governance_artifact_update

forbiddenActions:
  - push_to_upstream
  - force_push
  - merge
  - release
  - deploy
  - dependency_or_pom_changes
  - src_test_changes
  - public_readiness_claim
  - public_correctness_claim
  - public_security_claim
  - public_compliance_claim

validation:
  javaHome: C:\Program Files\Java\jdk-17
  diffCheckCommand: git diff --check
  mavenTestCommand: .\mvnw.cmd test
  fullMavenTestRequiredPerCandidate: true

terminalBoundary:
  afterLocalCommit: hold_at_local_commit_boundary
  draftPrAllowed: $draftPrValue
  mergeAllowed: false
"@

$lease | Set-Content $LeasePath

$state = [ordered]@{
    schemaVersion = "threshold.petclinic.lease-state.v0.2"
    invocationId = $invocationId
    leaseId = $LeaseName
    mode = $Mode
    branch = $branch
    startHead = $head
    currentHead = $head
    currentSourceHead = $head
    candidatesProcessed = 0
    commitsCreated = 0
    remainingBudget = [ordered]@{
        candidates = $MaxCandidatesThisRun
        commits = $MaxCommitsThisRun
        repairAttempts = $MaxRepairAttemptsPerCandidate
    }
    lastReceipt = $null
    terminalState = "active"
    updatedAt = (Get-Date).ToUniversalTime().ToString("o")
}

$state | ConvertTo-Json -Depth 8 | Set-Content $StatePath

Write-Host "Threshold lease started"
Write-Host "leasePath=$(ConvertTo-RepoPath $LeasePath)"
Write-Host "statePath=$(ConvertTo-RepoPath $StatePath)"
Write-Host "branch=$branch"
Write-Host "startHead=$head"
Write-Host "budget.candidates=$MaxCandidatesThisRun"
Write-Host "budget.commits=$MaxCommitsThisRun"
