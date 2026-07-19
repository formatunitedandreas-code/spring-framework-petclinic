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

function Get-PetClinicSpringBindingEvidence {
    [CmdletBinding()]
    param(
        [string] $SourceRoot = "src/main/java",
        [string] $ResourceRoot = "src/main/resources"
    )

    $patterns = @("@Controller", "@Service", "@Repository", "@Component", "@Bean", "@Autowired")
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($root in @($SourceRoot, $ResourceRoot)) {
        if (-not (Test-Path $root)) { continue }
        $files = @(Get-ChildItem -Path $root -Recurse -File |
            Where-Object { $_.Extension -in @(".java", ".xml", ".properties") } |
            Sort-Object FullName)
        foreach ($file in $files) {
            $text = Get-Content $file.FullName -Raw
            foreach ($pattern in $patterns) {
                if ($text.Contains($pattern)) {
                    $relative = Resolve-PetClinicAdapterRepoPath -Path $file.FullName
                    $matches.Add([pscustomobject]@{
                        path = $relative
                        binding = $pattern
                        evidenceRef = "source:$relative"
                    })
                }
            }
        }
    }

    return [pscustomobject]@{
        extractor = "petclinic.spring-binding.v0.1"
        bindings = @($matches.ToArray())
    }
}
