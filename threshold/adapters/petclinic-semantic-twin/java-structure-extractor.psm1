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

function Get-PetClinicJavaStructureEvidence {
    [CmdletBinding()]
    param(
        [string] $SourceRoot = "src/main/java"
    )

    if (-not (Test-Path $SourceRoot)) {
        throw "java_source_root_missing=$SourceRoot"
    }

    $files = @(Get-ChildItem -Path $SourceRoot -Recurse -Filter *.java | Sort-Object FullName)
    return [pscustomobject]@{
        extractor = "petclinic.java-structure.v0.1"
        sourceRoot = $SourceRoot
        fileCount = $files.Count
        classes = @($files | ForEach-Object {
            $relative = Resolve-PetClinicAdapterRepoPath -Path $_.FullName
            [pscustomobject]@{
                path = $relative
                evidenceRef = "source:$relative"
            }
        })
    }
}
