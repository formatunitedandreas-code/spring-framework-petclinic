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
        CapabilityKgPath = "threshold/kgs/capability-kg.json"
        FidelityKgPath = "threshold/kgs/fidelity-kg.json"
        TrainerReportPath = "threshold/trainer/training-report.json"
        ReviewFindingsPath = "threshold/trainer/review-findings.json"
        ReceiptChainPath = "threshold/attestations/receipt-chain.json"
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
            "ReceiptDirectory",
            "CapabilityKg",
            "FidelityKg",
            "TrainerReport",
            "ReviewFindings",
            "ReceiptChain"
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
        "CapabilityKg" { return $paths.CapabilityKgPath }
        "FidelityKg" { return $paths.FidelityKgPath }
        "TrainerReport" { return $paths.TrainerReportPath }
        "ReviewFindings" { return $paths.ReviewFindingsPath }
        "ReceiptChain" { return $paths.ReceiptChainPath }
    }
}
