[CmdletBinding()]
param(
    [string] $BaseRef = "origin/main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/branch-range-validation.ps1")

function Get-JavaPublicSurface {
    param([string] $Text)
    return @(
        [regex]::Matches($Text, '(?m)^\s*(public|protected)\s+(?:static\s+)?(?:final\s+)?[A-Za-z0-9_<>, ?\[\].]+\s+[A-Za-z0-9_]+\s*\([^;{}]*\)') |
            ForEach-Object { ($_.Value -replace "\s+", " ").Trim() } |
            Sort-Object -Unique
    )
}

function Get-GitTextOrEmpty {
    param([string] $Revision, [string] $Path)
    $text = @(& git show "$Revision`:$Path" 2>$null)
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($text -join "`n")
}

$changedJavaFiles = @(& git diff --name-only "$BaseRef...HEAD" -- "src/main/java/**/*.java" | Sort-Object -Unique)
foreach ($path in $changedJavaFiles) {
    $before = Get-GitTextOrEmpty -Revision $BaseRef -Path $path
    $after = Get-Content $path -Raw
    $beforeSurface = Get-JavaPublicSurface -Text $before
    $afterSurface = Get-JavaPublicSurface -Text $after
    if (($beforeSurface -join "`n") -ne ($afterSurface -join "`n")) {
        throw "semantic_public_surface_changed=$path"
    }
}

Assert-ThresholdBranchRangeDiffClean -BaseRef $BaseRef

& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd test"
if ($LASTEXITCODE -ne 0) { throw "semantic_maven_test_failed" }

Write-Host "semanticCorrectness=passed"
Write-Host "checkedJavaFiles=$($changedJavaFiles.Count)"
Write-Host "publicSurfaceStable=true"
