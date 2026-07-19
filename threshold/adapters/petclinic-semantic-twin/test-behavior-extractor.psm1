[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Resolve-PetClinicAdapterRepoPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $root = (git rev-parse --show-toplevel).Trim()
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($root)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($fullPath.Substring($fullRoot.Length).TrimStart("\", "/") -replace "\\", "/")
    }
    return ($Path -replace "\\", "/")
}

function Get-PetClinicTestBehaviorEvidence {
    [CmdletBinding()]
    param(
        [string] $TestRoot = "src/test"
    )

    if (-not (Test-Path $TestRoot)) {
        return [pscustomobject]@{
            extractor = "petclinic.test-behavior.v0.1"
            tests = @()
        }
    }

    $tests = @(Get-ChildItem -Path $TestRoot -Recurse -File |
        Where-Object { $_.Extension -in @(".java", ".xml") } |
        Sort-Object FullName |
        ForEach-Object {
        $relative = Resolve-PetClinicAdapterRepoPath -Path $_.FullName
        [pscustomobject]@{
            path = $relative
            evidenceRef = "test:$relative"
        }
    })

    return [pscustomobject]@{
        extractor = "petclinic.test-behavior.v0.1"
        tests = $tests
    }
}
