[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-ThresholdRuntimePaths {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        LeasePath = "threshold/leases/current.yaml"
        LeaseStatePath = "threshold/lease-state/current-run.json"
        CandidatePocketPath = "threshold/candidate-pocket/current.json"
        AutoPatchableGatePath = "threshold/gates/auto-patchable-candidate-classes.json"
        ReceiptDirectory = "threshold/receipts"
    }
}

function Resolve-ThresholdRuntimePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "Lease",
            "LeaseState",
            "CandidatePocket",
            "AutoPatchableGate",
            "ReceiptDirectory"
        )]
        [string] $Name
    )

    $paths = Get-ThresholdRuntimePaths
    switch ($Name) {
        "Lease" { return $paths.LeasePath }
        "LeaseState" { return $paths.LeaseStatePath }
        "CandidatePocket" { return $paths.CandidatePocketPath }
        "AutoPatchableGate" { return $paths.AutoPatchableGatePath }
        "ReceiptDirectory" { return $paths.ReceiptDirectory }
    }
}
