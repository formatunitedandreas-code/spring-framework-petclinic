[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-PetClinicQueryObservationEvidence {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        extractor = "petclinic.query-observation.v0.1"
        observations = @()
        status = "not_materialized"
        reason = "runtime query observations are collected during semantic workorder validation"
    }
}
