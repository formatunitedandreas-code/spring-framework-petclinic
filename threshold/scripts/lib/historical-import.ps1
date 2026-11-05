Set-StrictMode -Version Latest

function Test-ThresholdInertHistoricalImport {
    param([Parameter(Mandatory = $true)][string] $BaseRef)

    $rawPaths = @(& git diff --no-ext-diff --no-textconv --no-renames --name-only -z $BaseRef HEAD) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the final historical-import delta.' }
    if ($rawPaths -notmatch '(^|\x00)threshold/runs/historical-imports/') { return $false }

    $pythonNames = if ($env:OS -eq 'Windows_NT') { @('python', 'python3') } else { @('python3', 'python') }
    $python = $null
    foreach ($name in $pythonNames) {
        $python = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $python) { break }
    }
    if ($null -eq $python) { throw 'Python 3.10+ is required for historical-import verification.' }
    $repo = (& git rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve historical-import repository.' }
    $validator = Join-Path (Split-Path $PSScriptRoot -Parent) 'historical_imports.py'
    $output = @(& $python.Source $validator validate --repository $repo --base $BaseRef --head HEAD 2>&1)
    $code = $LASTEXITCODE
    if ($code -eq 3) { return $false }
    if ($code -ne 0) { throw "Invalid historical import: $($output -join ' ')" }
    foreach ($line in $output) { Write-Host $line }
    return $true
}
