[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function New-PetClinicTargetMappingProposal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $LegacyTwin,

        [string] $Objective = "preserve verified behavior while reducing refactoring candidate fragmentation"
    )

    return [pscustomobject]@{
        schemaVersion = "threshold.target-twin.v0.1"
        proposalId = "target-twin:$($LegacyTwin.sourceHead)"
        legacyTwinDigest = $LegacyTwin.twinDigest
        preservedCapabilities = @($LegacyTwin.capabilities | ForEach-Object { $_.id })
        preservedBehaviorInvariants = @($LegacyTwin.behaviorInvariants | ForEach-Object { $_.id })
        proposedCapabilities = @($LegacyTwin.capabilities)
        proposedBoundaries = @()
        proposedDependencyEdges = @($LegacyTwin.dependencyEdges)
        transformations = @()
        objectives = @(@{ metric = "candidateFragmentation"; target = "reduced" })
        assumptions = @(@{ id = "proposal-only"; statement = $Objective })
        unresolvedQuestions = @()
        authorityFlags = @{
            execute = $false
            commit = $false
            push = $false
            merge = $false
        }
    }
}
