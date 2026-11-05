[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/test-fixture-directory.ps1")

function Assert-CleanupRefused {
    param([object] $Fixture)
    try { Remove-ThresholdOwnedFixtureDirectory -Fixture $Fixture }
    catch { if ($_.Exception.Message -match '^Refusing fixture cleanup') { return }; throw }
    throw "Unsafe fixture cleanup was accepted."
}
$owned = New-ThresholdOwnedFixtureDirectory -Prefix "threshold-owned-cleanup"
$sibling = New-ThresholdOwnedFixtureDirectory -Prefix "threshold-sibling-cleanup"
try {
    "keep" | Set-Content -LiteralPath (Join-Path $sibling.Path "sentinel.txt")
    Assert-CleanupRefused ([pscustomobject]@{ Path = $sibling.Path; Parent = $owned.Parent; Name = $owned.Name })
    Assert-CleanupRefused ([pscustomobject]@{ Path = $owned.Path; Parent = $sibling.Path; Name = $owned.Name })
    if (-not (Test-Path -LiteralPath (Join-Path $sibling.Path "sentinel.txt"))) { throw "Sibling artifact was removed." }
    if ($env:OS -ne "Windows_NT") {
        $link = Join-Path $owned.Path "outside-link"
        New-Item -ItemType SymbolicLink -Path $link -Target $sibling.Path | Out-Null
        Assert-CleanupRefused $owned
        if (-not (Test-Path -LiteralPath (Join-Path $sibling.Path "sentinel.txt"))) { throw "Linked sibling artifact was removed." }
        Remove-Item -LiteralPath $link -Force
    }
}
finally {
    Remove-ThresholdOwnedFixtureDirectory -Fixture $owned
    Remove-ThresholdOwnedFixtureDirectory -Fixture $sibling
}
Write-Host "ownedFixtureCleanup=passed"
