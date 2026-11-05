Set-StrictMode -Version Latest

function Test-ThresholdFiniteManualSourceCandidate {
    param([Parameter(Mandatory = $true)][string] $BaseRef)
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_EVENT_PATH) -or -not (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH -PathType Leaf)) {
        return $false
    }
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    $number = $event.PSObject.Properties["number"]
    if ($null -eq $number -or $number.Value -ne 184) { return $false }
    $pythonNames = if ($env:OS -eq 'Windows_NT') { @('python', 'python3') } else { @('python3', 'python') }
    $python = $null
    foreach ($name in $pythonNames) {
        $python = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $python) { break }
    }
    if ($null -eq $python) { throw 'Python 3.10+ is required for finite current source verification.' }
    $repo = (& git rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve source repository.' }
    $validator = Join-Path (Split-Path $PSScriptRoot -Parent) 'finite_manual_source.py'
    $output = @(& $python.Source -B $validator --repository $repo --base $BaseRef --event $env:GITHUB_EVENT_PATH --checkout HEAD 2>&1)
    $code = $LASTEXITCODE
    if ($code -eq 3) { return $false }
    if ($code -ne 0) { throw "Invalid finite current source candidate: $($output -join ' ')" }
    foreach ($line in $output) { Write-Host $line }
    return $true
}
