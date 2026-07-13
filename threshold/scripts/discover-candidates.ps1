[CmdletBinding()]
param(
    [string] $LeasePath = "threshold/leases/current.yaml",
    [string] $PocketPath = "threshold/candidate-pocket/current.json",
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

function ConvertTo-RepoPath {
    param([string] $Path)
    return ($Path -replace "\\", "/").Trim()
}

function New-CandidateId {
    param([string] $Path, [string] $CandidateClass, [string] $Member)
    $stem = "$Path-$CandidateClass-$Member".ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $stem.Trim("-")
}

if (-not (Test-Path $LeasePath)) {
    throw "Lease file not found: $LeasePath"
}

$leaseLines = Get-Content $LeasePath
$leaseName = Get-LeaseScalar $leaseLines "leaseName"
$branch = Get-LeaseScalar $leaseLines "branch"
$head = (& git rev-parse HEAD).Trim()

$sourceFiles = @(
    Get-ChildItem "src/main/java/org/springframework/samples/petclinic" -Recurse -Filter "*.java" |
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

    $returnLocalPattern = "(?ms)(?<type>[A-Z][A-Za-z0-9_<>, ?]+)\s+(?<name>[a-z][A-Za-z0-9_]*)\s*=\s*(?<expr>[^;]+);\s*return\s+\k<name>\s*;"
    foreach ($match in [regex]::Matches($content, $returnLocalPattern)) {
        $member = $match.Groups["name"].Value
        $score = 30 + 30 + 20 + 12 + 10 + $layerScore
        $candidates.Add([ordered]@{
            candidateId = New-CandidateId $path "redundant_local_variable_simplification" $member
            candidateClass = "redundant_local_variable_simplification"
            score = $score
            file = $path
            member = $member
            expectedDiffSummary = "Inline local variable '$member' immediately returned from the same block."
            estimatedChangedLines = 2
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    $longLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Length -gt 120 -and $lines[$i] -match "^\s*(private|public|return|[A-Za-z0-9_]+\.)") {
            $longLines += ($i + 1)
        }
    }
    if ($longLines.Count -gt 0) {
        $member = "line-$($longLines[0])"
        $candidateClass = if ($path -like "*/repository/*") { "repository_readability_cleanup" } else { "private_helper_extraction_for_readability" }
        $score = 30 + 30 + 20 + 10 + $layerScore
        $candidates.Add([ordered]@{
            candidateId = New-CandidateId $path $candidateClass $member
            candidateClass = $candidateClass
            score = $score
            file = $path
            member = $member
            expectedDiffSummary = "Wrap or locally extract long readability line without changing behavior."
            estimatedChangedLines = [Math]::Min(8, $longLines.Count * 2)
            tieBreak = [ordered]@{ layerScore = $layerScore; path = $path; member = $member }
        })
    }

    $stringMatches = [regex]::Matches($content, '"([^"\\\r\n]|\\.)+"') |
        ForEach-Object { $_.Value } |
        Where-Object {
            $_ -notmatch '^"/' -and
            $_ -notmatch '^"redirect:' -and
            $_ -notmatch '^"[A-Z_]+"$'
        } |
        Group-Object |
        Where-Object { $_.Count -ge 2 } |
        Sort-Object @{ Expression = { $_.Count }; Descending = $true }, Name

    foreach ($group in $stringMatches | Select-Object -First 2) {
        $literalName = ($group.Name.Trim('"') -replace "[^A-Za-z0-9]+", "-").Trim("-")
        if ([string]::IsNullOrWhiteSpace($literalName)) { continue }
        $score = 30 + 30 + 20 + 10 + $layerScore
        $candidates.Add([ordered]@{
            candidateId = New-CandidateId $path "duplicate_literal_local_constant_extraction" $literalName
            candidateClass = "duplicate_literal_local_constant_extraction"
            score = $score
            file = $path
            member = $literalName
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
        scannedFiles = $sourceFiles.Count
        ranking = @(
            "score descending",
            "estimated changed lines ascending",
            "candidate class lexical",
            "file path lexical",
            "member lexical"
        )
    }
    candidates = $ranked
    nextRecommendedCandidateId = if ($ranked.Count -gt 0) { $ranked[0].candidateId } else { $null }
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
Write-Host "nextRecommendedCandidateId=$($pocket.nextRecommendedCandidateId)"
