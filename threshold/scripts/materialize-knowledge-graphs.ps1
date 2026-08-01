[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $GatePath = "threshold/gates/auto-patchable-candidate-classes.json",
    [string] $ReceiptRoot = "threshold/receipts",
    [string] $ReviewFindingsPath = "threshold/trainer/review-findings.json",
    [string] $CapabilityKgPath = "threshold/kgs/capability-kg.json",
    [string] $FidelityKgPath = "threshold/kgs/fidelity-kg.json",
    [string] $TrainingReportPath = "threshold/trainer/training-report.json",
    [string] $CanaryRulesPath = "threshold/trainer/generated-canary-rules.json",
    [string] $PrBaseHead = "",
    [string] $BaseRef = "",
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/candidate-class-provenance.ps1")
. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function ConvertTo-RepoRelativePath {
    param([string] $Path)
    $repoRoot = (& git rev-parse --show-toplevel).Trim()
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($repoRoot)
    if ($resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ConvertTo-RepoPath $resolved.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return ConvertTo-RepoPath $Path
}

function Read-JsonOrNull {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Get-JsonProperty {
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

function Get-LeaseList {
    param([string[]] $Lines, [string] $Name)
    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") { $inside = $true; continue }
        if ($inside -and $line -match "^\S") { break }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") { $items.Add(($Matches[1]).Trim()) }
    }
    return @($items.ToArray())
}

function Get-LeaseScalarOrDefault {
    param([string[]] $Lines, [string] $Name, [string] $DefaultValue = "")
    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) { return $DefaultValue }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-UniqueMatches {
    param([string] $Text, [string] $Pattern, [string] $GroupName)
    return @(
        [regex]::Matches($Text, $Pattern) |
            ForEach-Object { [string]$_.Groups[$GroupName].Value } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Write-JsonFile {
    param([string] $Path, [object] $Value)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $Value | ConvertTo-Json -Depth 16 | Set-Content $Path
}

function Resolve-ObservedPrBaseHead {
    param([string] $PrBaseHead, [string] $BaseRef)
    if (-not [string]::IsNullOrWhiteSpace($PrBaseHead)) {
        return [string]$PrBaseHead
    }
    if (-not [string]::IsNullOrWhiteSpace($env:THRESHOLD_PR_BASE_HEAD)) {
        return [string]$env:THRESHOLD_PR_BASE_HEAD
    }
    if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
        $resolved = (& git rev-parse "origin/${BaseRef}" 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$resolved)) {
            return [string]($resolved.Trim())
        }
    }
    return ""
}

function ConvertTo-NormalizedJson {
    param([object] $Value)
    return ($Value | ConvertTo-Json -Depth 16).Trim()
}

function Get-StringSha256Lower {
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

function New-SemanticDigest {
    param([string[]] $Lines)
    $sorted = [string[]]@($Lines)
    [array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return Get-StringSha256Lower -Text ([string]::Join("`n", $sorted))
}

function Assert-FileMatches {
    param([string] $Path, [object] $Expected)
    if (-not (Test-Path $Path)) { throw "kg_artifact_missing=$Path" }
    $actualObject = Get-Content $Path -Raw | ConvertFrom-Json
    $actualDigest = Get-JsonProperty $actualObject "semanticDigest" ""
    $expectedDigest = Get-JsonProperty $Expected "semanticDigest" ""
    if (-not [string]::IsNullOrWhiteSpace([string]$actualDigest) -and -not [string]::IsNullOrWhiteSpace([string]$expectedDigest)) {
        if ([string]$actualDigest -ne [string]$expectedDigest) {
            throw "kg_artifact_stale=$Path actualDigest=$actualDigest expectedDigest=$expectedDigest"
        }
        return
    }
    $actualJson = ConvertTo-NormalizedJson $actualObject
    $expectedJson = ConvertTo-NormalizedJson $Expected
    if ($actualJson -ne $expectedJson) {
        throw "kg_artifact_stale=$Path"
    }
}

if (-not (Test-Path $LeasePath)) { throw "Missing lease: $LeasePath" }
if (-not (Test-Path $GatePath)) { throw "Missing gate: $GatePath" }

$leaseLines = Get-Content $LeasePath
$leaseAllowedClasses = @(Get-LeaseList -Lines $leaseLines -Name "allowedCandidateTypes")
$leaseAllowedPaths = @(Get-LeaseList -Lines $leaseLines -Name "allowedPaths")
$leaseForbiddenActions = @(Get-LeaseList -Lines $leaseLines -Name "forbiddenActions")
$leaseBranch = Get-LeaseScalarOrDefault -Lines $leaseLines -Name "branch"
$leaseName = Get-LeaseScalarOrDefault -Lines $leaseLines -Name "leaseName"
$observedPrBaseHead = Resolve-ObservedPrBaseHead -PrBaseHead $PrBaseHead -BaseRef $BaseRef

$gate = Get-Content $GatePath -Raw | ConvertFrom-Json
$gateClasses = @(Get-JsonProperty $gate "approvedAutoPatchableCandidateClasses" @() | ForEach-Object {
    $value = Get-JsonProperty $_ "candidateClass" ""
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) { [string]$value }
} | Sort-Object -Unique)
$gatePilotAutoClasses = @(Get-JsonProperty $gate "approvedAutoPatchableCandidateClasses" @() | ForEach-Object {
    $value = Get-JsonProperty $_ "candidateClass" ""
    $pilot = Get-JsonProperty $_ "pilotAutoPatchableAtF2" $false
    if (-not [string]::IsNullOrWhiteSpace([string]$value) -and $pilot -eq $true) { [string]$value }
} | Sort-Object -Unique)
$batchMode = Get-JsonProperty $gate "batchReceiptMode" $null
$batchClasses = @(Get-JsonProperty $batchMode "approvedCandidateClasses" @() | ForEach-Object {
    $value = Get-JsonProperty $_ "candidateClass" ""
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) { [string]$value }
} | Sort-Object -Unique)

$discoveryText = Get-Content "threshold/scripts/discover-candidates.ps1" -Raw
$discoveryClasses = @(
    @(Get-UniqueMatches -Text $discoveryText -Pattern 'Add-Candidate\s+-CandidateClass\s+"(?<class>[a-z0-9_]+)"' -GroupName "class") +
    @(Get-UniqueMatches -Text $discoveryText -Pattern '\$candidateClass\s*=\s*"(?<class>[a-z0-9_]+)"' -GroupName "class") +
    @(Get-UniqueMatches -Text $discoveryText -Pattern '\$candidateClass\s*=\s*if\s*\([^)]+\)\s*\{\s*"(?<class>[a-z0-9_]+)"' -GroupName "class") +
    @(Get-UniqueMatches -Text $discoveryText -Pattern '\$candidateClass\s*=\s*if\s*\([^)]+\)\s*\{\s*"[^"]+"\s*\}\s*else\s*\{\s*"(?<class>[a-z0-9_]+)"' -GroupName "class") |
        Sort-Object -Unique
)
$runnerText = Get-Content "threshold/scripts/run-next-slice.ps1" -Raw
$runnerClasses = @(
    Get-UniqueMatches -Text $runnerText -Pattern '"(?<class>[a-z0-9_]+)"\s*\{' -GroupName "class" |
        Where-Object { $_ -like "*_*" -and $_ -ne "collapse_extra_blank_line" } |
        Sort-Object -Unique
)

$receiptFiles = @(Get-ChildItem $ReceiptRoot -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object { ConvertTo-RepoRelativePath $_.FullName })
$receiptEvidence = New-Object System.Collections.Generic.List[object]
$classStats = @{}
foreach ($receiptFile in $receiptFiles) {
    try {
        $receipt = Get-Content $receiptFile.FullName -Raw | ConvertFrom-Json
    }
    catch {
        continue
    }
    $candidateClassValue = Get-JsonProperty $receipt "candidateClass" ""
    $batchClassValue = Get-JsonProperty $receipt "batchClass" ""
    $candidateClass = if (-not [string]::IsNullOrWhiteSpace([string]$candidateClassValue)) { [string]$candidateClassValue } elseif (-not [string]::IsNullOrWhiteSpace([string]$batchClassValue)) { [string]$batchClassValue } else { "unknown" }
    $repoReceiptPath = ConvertTo-RepoRelativePath $receiptFile.FullName
    $receiptChangedInCurrentPr = $false
    if (-not [string]::IsNullOrWhiteSpace($observedPrBaseHead)) {
        $changedInCurrentPr = @(git diff --name-only "${observedPrBaseHead}...HEAD" -- $repoReceiptPath 2>$null)
        $receiptChangedInCurrentPr = $LASTEXITCODE -eq 0 -and $changedInCurrentPr.Count -gt 0
    }

    $receiptPrBaseHead = ""
    if ($receiptChangedInCurrentPr) {
        $receiptPrBaseHead = Resolve-ThresholdReceiptPrBaseHead -Receipt $receipt -ReceiptPath $repoReceiptPath
    }
    else {
        try {
            $receiptPrBaseHead = Resolve-ThresholdReceiptPrBaseHead -Receipt $receipt -ReceiptPath $repoReceiptPath
        }
        catch {
            $receiptPrBaseHead = $observedPrBaseHead
        }
    }
    Assert-ThresholdCandidateClassProvenance -Receipt $receipt -ReceiptPath $repoReceiptPath -PrBaseHead $receiptPrBaseHead
    $positiveLearningEligible = Test-ThresholdCandidateClassProvenancePositiveLearningEligible -Receipt $receipt
    if (-not $classStats.ContainsKey($candidateClass)) {
        $classStats[$candidateClass] = [ordered]@{
            receiptCount = 0
            validationPassCount = 0
            validationFailCount = 0
            semanticPassCount = 0
            semanticUnknownCount = 0
            reviewFindingCount = 0
        }
    }
    $stats = $classStats[$candidateClass]
    $validation = Get-JsonProperty $receipt "validation" $null
    $validationResultValue = Get-JsonProperty $validation "result" ""
    $validationResult = if (-not [string]::IsNullOrWhiteSpace([string]$validationResultValue)) { [string]$validationResultValue } else { "UNKNOWN" }
    $semanticValidation = Get-JsonProperty $receipt "semanticValidation" $null
    $semanticResult = Get-JsonProperty $semanticValidation "result" ""
    if ($positiveLearningEligible) {
        $stats.receiptCount += 1
        if ($validationResult -match "SUCCESS|passed|SKIPPED_BY_LEASE_INVOCATION") { $stats.validationPassCount += 1 } else { $stats.validationFailCount += 1 }
        if ($semanticResult -eq "passed") { $stats.semanticPassCount += 1 } else { $stats.semanticUnknownCount += 1 }
    }

    $receiptEvidence.Add([ordered]@{
        id = ConvertTo-RepoRelativePath $receiptFile.FullName
        candidateClass = $candidateClass
        positiveLearningEligible = [bool]$positiveLearningEligible
        sourceCommit = if (-not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty $receipt "commitHash" ""))) { [string](Get-JsonProperty $receipt "commitHash" "") } elseif (-not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty $receipt "sourceCommit" ""))) { [string](Get-JsonProperty $receipt "sourceCommit" "") } else { $null }
        leaseDigest = if (-not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty $receipt "leaseDigest" ""))) { [string](Get-JsonProperty $receipt "leaseDigest" "") } else { $null }
        validationResult = $validationResult
        changedFiles = @(Get-JsonProperty $receipt "changedFiles" @() | ForEach-Object {
            $pathValue = Get-JsonProperty $_ "path" ""
            if ($_ -is [string]) { [string]$_ } elseif (-not [string]::IsNullOrWhiteSpace([string]$pathValue)) { [string]$pathValue }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    })
}

$reviewFindings = Read-JsonOrNull -Path $ReviewFindingsPath
$findingNodes = @()
if ($reviewFindings -and (Get-JsonProperty $reviewFindings "findings" $null)) {
    foreach ($finding in @(Get-JsonProperty $reviewFindings "findings" @())) {
        $findingClass = Get-JsonProperty $finding "candidateClass" ""
        $className = if (-not [string]::IsNullOrWhiteSpace([string]$findingClass)) { [string]$findingClass } else { "unknown" }
        if (-not $classStats.ContainsKey($className)) {
            $classStats[$className] = [ordered]@{
                receiptCount = 0; validationPassCount = 0; validationFailCount = 0; semanticPassCount = 0; semanticUnknownCount = 0; reviewFindingCount = 0
            }
        }
        $classStats[$className].reviewFindingCount += 1
        $findingNodes += [ordered]@{
            id = [string](Get-JsonProperty $finding "id" "")
            candidateClass = $className
            severity = if (-not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty $finding "severity" ""))) { [string](Get-JsonProperty $finding "severity" "") } else { "P2" }
            ruleSuggestion = [string](Get-JsonProperty $finding "ruleSuggestion" "")
            canarySuggestion = [string](Get-JsonProperty $finding "canarySuggestion" "")
        }
    }
}

$capabilityNodes = New-Object System.Collections.Generic.List[object]
$fidelityNodes = New-Object System.Collections.Generic.List[object]
$trainingDecisions = New-Object System.Collections.Generic.List[object]
$allClasses = @($leaseAllowedClasses + $gateClasses + $discoveryClasses + $runnerClasses + $batchClasses + @($classStats.Keys) | Sort-Object -Unique)
foreach ($className in $allClasses) {
    $stats = if ($classStats.ContainsKey($className)) { $classStats[$className] } else {
        [ordered]@{ receiptCount = 0; validationPassCount = 0; validationFailCount = 0; semanticPassCount = 0; semanticUnknownCount = 0; reviewFindingCount = 0 }
    }
    $isInLease = $leaseAllowedClasses -contains $className
    $isInGate = $gateClasses -contains $className
    $isPilotAutoAtF2 = $gatePilotAutoClasses -contains $className
    $isDiscovered = $discoveryClasses -contains $className
    $isExecutable = $runnerClasses -contains $className
    $isBatch = $batchClasses -contains $className
    $passRate = if ([int]$stats.receiptCount -gt 0) { [math]::Round([double]$stats.validationPassCount / [double]$stats.receiptCount, 4) } else { 0.0 }
    $passRateText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.####}", $passRate)

    $level = "F0_UNOBSERVED"
    if ($stats.reviewFindingCount -gt 0 -or $stats.validationFailCount -gt 0) { $level = "F1_REVIEW_REQUIRED" }
    elseif ($stats.receiptCount -ge 3 -and $passRate -ge 0.95 -and $isInGate -and $isExecutable -and $isDiscovered) { $level = "F4_CI_RECEIPT_STABLE" }
    elseif ($stats.receiptCount -ge 1 -and $isInGate -and $isExecutable) { $level = "F3_VALIDATED_RECEIPT" }
    elseif ($isInGate -and $isExecutable) { $level = "F2_GATED_EXECUTOR" }

    $decision = "held"
    if ($level -in @("F3_VALIDATED_RECEIPT", "F4_CI_RECEIPT_STABLE") -and $isInLease -and $isInGate -and $isExecutable -and $isDiscovered -and $stats.reviewFindingCount -eq 0) {
        $decision = "autoPatchable"
    }
    elseif ($level -eq "F2_GATED_EXECUTOR" -and $isPilotAutoAtF2 -and $isInLease -and $isInGate -and $isExecutable -and $isDiscovered -and $stats.reviewFindingCount -eq 0) {
        $decision = "autoPatchable"
    }
    elseif ($level -ne "F0_UNOBSERVED" -or $isInGate -or $isDiscovered) {
        $decision = "reviewOnly"
    }

    $capabilityNodes.Add([ordered]@{
        id = "capability:$className"
        candidateClass = $className
        allowedByLease = $isInLease
        approvedByGate = $isInGate
        pilotAutoPatchableAtF2 = $isPilotAutoAtF2
        discoveredByRunner = $isDiscovered
        executableByRunner = $isExecutable
        batchExecutable = $isBatch
        forbiddenActions = $leaseForbiddenActions
        allowedPathCount = $leaseAllowedPaths.Count
        trainerDecision = $decision
    })
    $fidelityNodes.Add([ordered]@{
        id = "fidelity:$className"
        candidateClass = $className
        level = $level
        receiptCount = [int]$stats.receiptCount
        validationPassCount = [int]$stats.validationPassCount
        validationFailCount = [int]$stats.validationFailCount
        semanticPassCount = [int]$stats.semanticPassCount
        semanticUnknownCount = [int]$stats.semanticUnknownCount
        reviewFindingCount = [int]$stats.reviewFindingCount
        validationPassRate = $passRateText
    })
    $trainingDecisions.Add([ordered]@{
        candidateClass = $className
        fidelityLevel = $level
        decision = $decision
        reason = "decision derived from lease, gate, discovery, executor, receipt history, semantic evidence, and review findings"
    })
}

$generatedAt = "deterministic-from-current-repo-state"
$leasePathNormalized = ConvertTo-RepoPath $LeasePath
$capabilityNodeArray = @($capabilityNodes.ToArray())
$fidelityNodeArray = @($fidelityNodes.ToArray())
$trainingDecisionArray = @($trainingDecisions.ToArray())
$receiptEvidenceArray = @($receiptEvidence.ToArray())
$capabilityKg = [ordered]@{
    schemaVersion = "threshold.petclinic.capability-kg.v0.1"
    generatedAt = $generatedAt
    lease = [ordered]@{ path = $leasePathNormalized; leaseName = $leaseName; branch = $leaseBranch }
    nodes = $capabilityNodeArray
    edges = @(
        @($capabilityNodeArray | ForEach-Object {
            [ordered]@{ from = $_.id; relation = "has_fidelity"; to = "fidelity:$($_.candidateClass)" }
        })
    )
}
$fidelityKg = [ordered]@{
    schemaVersion = "threshold.petclinic.fidelity-kg.v0.1"
    generatedAt = $generatedAt
    nodes = $fidelityNodeArray
    evidence = $receiptEvidenceArray
    reviewFindings = @($findingNodes)
    fidelityLevels = @(
        "F0_UNOBSERVED",
        "F1_REVIEW_REQUIRED",
        "F2_GATED_EXECUTOR",
        "F3_VALIDATED_RECEIPT",
        "F4_CI_RECEIPT_STABLE"
    )
}
$trainingReport = [ordered]@{
    schemaVersion = "threshold.petclinic.capability-trainer-report.v0.1"
    generatedAt = $generatedAt
    policy = [ordered]@{
        missingKgMeansStop = $true
        reviewFindingMeansNoAutoPatch = $true
        fidelityDrivesExecutionMode = $true
        immutableReceiptChainRequired = $true
        semanticValidationRequired = $true
    }
    decisions = $trainingDecisionArray
}
$generatedCanaryRules = [ordered]@{
    schemaVersion = "threshold.petclinic.generated-canary-rules.v0.1"
    generatedAt = $generatedAt
    source = ConvertTo-RepoPath $ReviewFindingsPath
    rules = @($findingNodes | Where-Object { -not [string]::IsNullOrWhiteSpace($_.canarySuggestion) } | ForEach-Object {
        [ordered]@{
            id = "review-finding-canary-$($_.id)"
            candidateClass = $_.candidateClass
            severity = $_.severity
            ruleSuggestion = $_.ruleSuggestion
            canarySuggestion = $_.canarySuggestion
            status = "generated_review_required"
        }
    })
}

$capabilityKg["semanticDigest"] = New-SemanticDigest @(
    "schema=$($capabilityKg.schemaVersion)"
    "lease=$($capabilityKg.lease.path)|$($capabilityKg.lease.leaseName)|$($capabilityKg.lease.branch)"
    @($capabilityNodeArray | ForEach-Object {
        "node=$($_.id)|$($_.candidateClass)|lease=$($_.allowedByLease)|gate=$($_.approvedByGate)|pilotF2=$($_.pilotAutoPatchableAtF2)|discover=$($_.discoveredByRunner)|exec=$($_.executableByRunner)|batch=$($_.batchExecutable)|paths=$($_.allowedPathCount)|decision=$($_.trainerDecision)"
    })
    @($capabilityKg.edges | ForEach-Object {
        "edge=$($_.from)|$($_.relation)|$($_.to)"
    })
)

$fidelityKg["semanticDigest"] = New-SemanticDigest @(
    "schema=$($fidelityKg.schemaVersion)"
    @($fidelityNodeArray | ForEach-Object {
        "node=$($_.id)|$($_.candidateClass)|$($_.level)|receipts=$($_.receiptCount)|pass=$($_.validationPassCount)|fail=$($_.validationFailCount)|semanticPass=$($_.semanticPassCount)|semanticUnknown=$($_.semanticUnknownCount)|review=$($_.reviewFindingCount)|rate=$($_.validationPassRate)"
    })
    @($receiptEvidenceArray | ForEach-Object {
        $evidenceId = Get-JsonProperty $_ "id" ""
        $evidenceClass = Get-JsonProperty $_ "candidateClass" ""
        $evidenceSource = Get-JsonProperty $_ "sourceCommit" ""
        $evidenceLease = Get-JsonProperty $_ "leaseDigest" ""
        $evidenceValidation = Get-JsonProperty $_ "validationResult" ""
        $evidenceSemantic = Get-JsonProperty $_ "semanticResult" ""
        $positiveLearning = Get-JsonProperty $_ "positiveLearningEligible" $false
        "evidence=$evidenceId|$evidenceClass|source=$evidenceSource|lease=$evidenceLease|validation=$evidenceValidation|semantic=$evidenceSemantic|positiveLearning=$positiveLearning"
    })
    @($findingNodes | ForEach-Object {
        "finding=$($_.id)|$($_.candidateClass)|$($_.severity)|rule=$($_.ruleSuggestion)|canary=$($_.canarySuggestion)"
    })
)

$trainingReport["semanticDigest"] = New-SemanticDigest @(
    "schema=$($trainingReport.schemaVersion)"
    "policy=missingKgMeansStop:$($trainingReport.policy.missingKgMeansStop)|reviewFindingMeansNoAutoPatch:$($trainingReport.policy.reviewFindingMeansNoAutoPatch)|fidelityDrivesExecutionMode:$($trainingReport.policy.fidelityDrivesExecutionMode)|immutableReceiptChainRequired:$($trainingReport.policy.immutableReceiptChainRequired)|semanticValidationRequired:$($trainingReport.policy.semanticValidationRequired)"
    @($trainingDecisionArray | ForEach-Object {
        "decision=$($_.candidateClass)|$($_.fidelityLevel)|$($_.decision)|$($_.reason)"
    })
)

$generatedCanaryRules["semanticDigest"] = New-SemanticDigest @(
    "schema=$($generatedCanaryRules.schemaVersion)"
    "source=$($generatedCanaryRules.source)"
    @($generatedCanaryRules.rules | ForEach-Object {
        "rule=$($_.id)|$($_.candidateClass)|$($_.severity)|$($_.ruleSuggestion)|$($_.canarySuggestion)|$($_.status)"
    })
)

if ($CheckOnly.IsPresent) {
    Assert-FileMatches -Path $CapabilityKgPath -Expected $capabilityKg
    Assert-FileMatches -Path $FidelityKgPath -Expected $fidelityKg
    Assert-FileMatches -Path $TrainingReportPath -Expected $trainingReport
    Assert-FileMatches -Path $CanaryRulesPath -Expected $generatedCanaryRules
}
else {
    Write-JsonFile -Path $CapabilityKgPath -Value $capabilityKg
    Write-JsonFile -Path $FidelityKgPath -Value $fidelityKg
    Write-JsonFile -Path $TrainingReportPath -Value $trainingReport
    Write-JsonFile -Path $CanaryRulesPath -Value $generatedCanaryRules
}

Write-Host "capabilityKg=$CapabilityKgPath"
Write-Host "fidelityKg=$FidelityKgPath"
Write-Host "trainingReport=$TrainingReportPath"
Write-Host "canaryRules=$CanaryRulesPath"
Write-Host "capabilityCount=$($capabilityNodes.Count)"
Write-Host "receiptEvidenceCount=$($receiptEvidence.Count)"
