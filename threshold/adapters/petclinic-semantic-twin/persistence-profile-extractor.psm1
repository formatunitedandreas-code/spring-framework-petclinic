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

function Get-PetClinicPersistenceProfileEvidence {
    [CmdletBinding()]
    param(
        [string[]] $Roots = @("src/main/java", "src/main/resources", "src/test")
    )

    $profileNames = @("jdbc", "jpa", "spring-data-jpa")
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($profile in $profileNames) {
        $files = @()
        foreach ($root in $Roots) {
            if (-not (Test-Path $root)) { continue }
            $files += @(Get-ChildItem -Path $root -Recurse -File |
                Where-Object { $_.FullName -match [regex]::Escape($profile) })
        }
        $files = @($files | Sort-Object FullName -Unique)
        $profiles.Add([pscustomobject]@{
            profile = $profile
            evidenceRefs = @($files | ForEach-Object { "source:$(Resolve-PetClinicAdapterRepoPath -Path $_.FullName)" })
        })
    }

    return [pscustomobject]@{
        extractor = "petclinic.persistence-profile.v0.1"
        profiles = @($profiles.ToArray())
    }
}
