[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Invoke-PetClinicSemanticRefactoringExecutor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Workorder,

        [switch] $PlanOnly
    )

    if ($PlanOnly) {
        return [pscustomobject]@{
            workorderId = $Workorder.workorderId
            execution = "plan_only"
            changedFiles = @()
        }
    }

    throw "semantic_executor_requires_admitted_bounded_implementation"
}
