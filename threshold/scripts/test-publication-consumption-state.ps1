[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib/publication-preflight.ps1")

$ledger = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-consumption-" + [guid]::NewGuid().ToString("N") + ".json")
function Assert-ConsumptionStop {
    param([string] $Name)
    try { Get-ConsumedAuthorityIds -Path $ledger | Out-Null }
    catch {
        if ($_.Exception.Message -match '^stop_consumption_state_unknown=') { Write-Host "expectedStop=$Name"; return }
        throw
    }
    throw "Invalid consumption ledger accepted: $Name"
}
try {
    Assert-ConsumptionStop "missing"
    foreach ($case in @(
        @{ name = "invalid-json"; json = '{' },
        @{ name = "null-root"; json = 'null' },
        @{ name = "array-root"; json = '[]' },
        @{ name = "missing-ids"; json = '{}' },
        @{ name = "wrong-domain"; json = '{"consumedAuthorityIds":["authority:old"]}' },
        @{ name = "mixed-domains"; json = '{"consumedAuthorityIds":[],"consumedConsumptionIds":[]}' },
        @{ name = "null-ids"; json = '{"consumedConsumptionIds":null}' },
        @{ name = "scalar-ids"; json = '{"consumedConsumptionIds":"consumption:old"}' },
        @{ name = "object-ids"; json = '{"consumedConsumptionIds":{}}' },
        @{ name = "empty-id"; json = '{"consumedConsumptionIds":[""]}' },
        @{ name = "whitespace-id"; json = '{"consumedConsumptionIds":[" "]}' },
        @{ name = "non-string-id"; json = '{"consumedConsumptionIds":[1]}' },
        @{ name = "duplicate-id"; json = '{"consumedConsumptionIds":["used","used"]}' }
    )) {
        [System.IO.File]::WriteAllText($ledger, $case.json, [System.Text.UTF8Encoding]::new($false))
        Assert-ConsumptionStop $case.name
    }
    [System.IO.File]::WriteAllText($ledger, '{"consumedConsumptionIds":[]}', [System.Text.UTF8Encoding]::new($false))
    if (@(Get-ConsumedAuthorityIds -Path $ledger).Count -ne 0) { throw "Explicit empty ledger changed" }
    [System.IO.File]::WriteAllText($ledger, '{"consumedConsumptionIds":["used","USED"]}', [System.Text.UTF8Encoding]::new($false))
    $ids = @(Get-ConsumedAuthorityIds -Path $ledger)
    if ($ids.Count -ne 2 -or $ids[0] -cne "used" -or $ids[1] -cne "USED") { throw "Consumption identities changed" }
    Write-Host "publicationConsumptionState=passed"
}
finally { Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue }
