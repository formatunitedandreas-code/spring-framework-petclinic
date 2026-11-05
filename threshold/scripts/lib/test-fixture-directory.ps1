Set-StrictMode -Version Latest

function New-ThresholdOwnedFixtureDirectory {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9-]+$')][string] $Prefix)
    $parent = (Get-Item -LiteralPath ([System.IO.Path]::GetTempPath()) -Force).FullName
    if ((Get-Item -LiteralPath $parent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Fixture temp parent must not be a reparse point."
    }
    $name = "$Prefix-$([guid]::NewGuid().ToString('N'))"
    $path = Join-Path $parent $name
    if (Test-Path -LiteralPath $path) { throw "Fixture directory unexpectedly already exists: $path" }
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ Path = $path; Parent = $parent; Name = $name }
}

function Remove-ThresholdOwnedFixtureDirectory {
    param([Parameter(Mandatory = $true)][object] $Fixture)
    $path = [System.IO.Path]::GetFullPath([string]$Fixture.Path)
    $expectedParent = [System.IO.Path]::GetFullPath([string]$Fixture.Parent).TrimEnd('\', '/')
    if ((Get-Item -LiteralPath $expectedParent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing fixture cleanup through a changed temp parent."
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    $actualParent = $item.Parent.FullName.TrimEnd('\', '/')
    if (-not $item.PSIsContainer -or $item.Name -cne $Fixture.Name -or
        -not $actualParent.Equals($expectedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing fixture cleanup outside its recorded direct temp parent."
    }
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($item)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing fixture cleanup through a reparse point."
        }
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing fixture cleanup containing a reparse point."
            }
            if ($entry -is [System.IO.DirectoryInfo]) { $pending.Push($entry) }
        }
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}
