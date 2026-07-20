[CmdletBinding()]
param(
    [string] $PrGovernancePath = "threshold/scripts/test-pr-governance.ps1",
    [string] $OutputPath = "threshold/runtime/reason-audit/publication-reason-boundary.json",
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function Write-JsonFile {
    param([string] $Path, [object] $Value)

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $Value | ConvertTo-Json -Depth 16 | Set-Content -Path $Path -Encoding UTF8
}

if (-not (Test-Path $PrGovernancePath)) {
    throw "reason_audit_target_missing=$PrGovernancePath"
}

$text = Get-Content $PrGovernancePath -Raw
$requiredMarkers = @(
    "Assert-CorePublicationAuthorityResult",
    "effectDecisions.publication",
    "publicationDecision.allowed",
    "Get-PublicationStopFromFailedConstraints",
    "publicationAuthorityReasonCodes",
    "postvalidation_branch_changed",
    "postvalidation_tree_changed",
    "publicationValidatedPushRef=git push origin"
)
$missingMarkers = @($requiredMarkers | Where-Object { $text -notmatch [regex]::Escape($_) })

$decisionLeakPatterns = @(
    '\$result\.decision\s*\)',
    'throw\s+\[string\]\s*\$result\.decision',
    '\$result\.reasonCodes\s*-contains',
    '\.reasonCodes\.Contains\(',
    'decisionFor\('
)
$decisionLeaks = @()
foreach ($pattern in $decisionLeakPatterns) {
    if ($text -match $pattern) {
        $decisionLeaks += $pattern
    }
}

$result = [ordered]@{
    schemaVersion = "threshold.petclinic.reason-boundary-audit.v0.1"
    generatedAt = "deterministic-from-current-repo-state"
    target = ConvertTo-RepoPath $PrGovernancePath
    nonAuthorizing = $true
    allowedEffects = @("observe", "shadowIntegration")
    decisionSurface = [ordered]@{
        authoritative = @(
            "valid",
            "evaluatedHead",
            "inputDigest",
            "effectDecisions.publication.allowed",
            "effectDecisions.publication.failedConstraintIds",
            "failedConstraintIds"
        )
        diagnosticOnly = @(
            "reasonCodes",
            "decision",
            "failedConstraintIds as report/projection data after the typed publication effect decision is evaluated"
        )
    }
    requiredMarkersPresent = ($missingMarkers.Count -eq 0)
    missingMarkers = $missingMarkers
    decisionLeakPatterns = $decisionLeaks
    passed = ($missingMarkers.Count -eq 0 -and $decisionLeaks.Count -eq 0)
    nonClaims = @(
        "reason audit is not publication authority",
        "reason audit is not merge authority",
        "Somnium or reason signals may not authorize publication",
        "Somnium shadow_ready is technical observation readiness only",
        "Somnium may only affect observe and shadowIntegration in this adapter lane",
        "SomniumDecision <= GuardianDecision <= AuthorityDecision is an ordering invariant",
        "Somnium outputs may not return as training truth through telemetry, Chunky bias, KG projection, or training artifacts without grounding and independent review",
        "Publication and merge readiness remain false until separate exact-head authority exists",
        "publication remains bound to typed effect decisions and rechecked head, branch, and tree"
    )
}

if (-not $result.passed) {
    if (-not $CheckOnly.IsPresent) {
        Write-JsonFile -Path $OutputPath -Value $result
    }
    throw "reason_boundary_audit_failed missingMarkers=$($missingMarkers -join ',') decisionLeaks=$($decisionLeaks -join ',')"
}

if (-not $CheckOnly.IsPresent) {
    Write-JsonFile -Path $OutputPath -Value $result
}

Write-Host "reasonBoundaryAudit=passed"
Write-Host "reasonBoundaryAuditOutput=$OutputPath"
Write-Host "reasonBoundaryAuditNonAuthorizing=true"
