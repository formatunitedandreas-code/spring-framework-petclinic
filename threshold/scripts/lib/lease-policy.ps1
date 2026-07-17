[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-ThresholdLeaseScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [string] $LeasePath = "lease"
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) {
        throw "Missing lease field '$Name' in $LeasePath"
    }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-ThresholdLeaseScalarOrNull {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(.+?)\s*$" } | Select-Object -First 1
    if (-not $match) {
        return $null
    }
    return ($match -replace "^\s*$([regex]::Escape($Name)):\s*", "").Trim()
}

function Get-ThresholdLeaseList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $items = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*$([regex]::Escape($Name)):\s*$") {
            $inside = $true
            continue
        }
        if ($inside -and $line -match "^\S") {
            break
        }
        if ($inside -and $line -match "^\s*-\s*(.+?)\s*$") {
            $items.Add(($Matches[1]).Trim())
        }
    }
    return @($items.ToArray())
}

function Get-ThresholdLeaseBoolean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $LeasePath
    )

    $value = Get-ThresholdLeaseScalar -Lines $Lines -Name $Name -LeasePath $LeasePath
    if ($value -eq "true") { return $true }
    if ($value -eq "false") { return $false }
    throw "Lease field '$Name' must be true or false in $LeasePath, got '$value'."
}

function Get-ThresholdLeaseBudgetValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $LeasePath
    )

    $match = $Lines | Where-Object { $_ -match "^\s*$([regex]::Escape($Name)):\s*(\d+)\s*$" } | Select-Object -First 1
    if (-not $match) {
        throw "Missing budget field '$Name' in $LeasePath"
    }
    return [int]($match -replace "^\s*$([regex]::Escape($Name)):\s*", "")
}

function Test-ThresholdPathAgainstPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Pattern
    )

    $normalizedPath = $Path -replace "\\", "/"
    $normalizedPattern = $Pattern -replace "\\", "/"
    return [System.Management.Automation.WildcardPattern]::new($normalizedPattern, "IgnoreCase").IsMatch($normalizedPath)
}

function Test-ThresholdGovernancePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    $normalized = $Path -replace "\\", "/"
    return (
        $normalized -like "threshold/scripts/*" -or
        $normalized -like "threshold/leases/*" -or
        $normalized -like "threshold/gates/*" -or
        $normalized -like "threshold/authority/*" -or
        $normalized -eq ".github/workflows/threshold-governance.yml" -or
        $normalized -eq ".github/CODEOWNERS"
    )
}

function Assert-ThresholdHeadPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $LeaseLines,
        [Parameter(Mandatory = $true)]
        [string] $LeasePath,
        [Parameter(Mandatory = $true)]
        [string] $CurrentHead,
        [Parameter(Mandatory = $true)]
        [string] $CurrentBranch
    )

    $headPolicy = Get-ThresholdLeaseScalar -Lines $LeaseLines -Name "headPolicy" -LeasePath $LeasePath
    $startHead = Get-ThresholdLeaseScalar -Lines $LeaseLines -Name "startHead" -LeasePath $LeasePath

    switch ($headPolicy) {
        "exactStartHead" {
            if ($CurrentHead -ne $startHead) {
                throw "HEAD mismatch. Expected '$startHead', got '$CurrentHead'."
            }
        }
        "descendantOfStartHead" {
            & git merge-base --is-ancestor $startHead HEAD
            if ($LASTEXITCODE -ne 0) {
                throw "HEAD '$CurrentHead' is not a descendant of lease startHead '$startHead'."
            }
        }
        "equalsOriginMainAtActivation" {
            $originMainAtActivation = Get-ThresholdLeaseScalar -Lines $LeaseLines -Name "originMainAtActivation" -LeasePath $LeasePath
            $baseRef = Get-ThresholdLeaseScalarOrNull -Lines $LeaseLines -Name "baseRef"
            if ([string]::IsNullOrWhiteSpace($baseRef)) {
                $baseRef = "origin/main"
            }
            $observedBase = (& git rev-parse $baseRef).Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($observedBase)) {
                throw "Failed to resolve lease baseRef '$baseRef'."
            }
            if ($observedBase -ne $originMainAtActivation) {
                throw "Base ref drift. expected $baseRef=$originMainAtActivation from activation, actual=$observedBase."
            }
            if ($CurrentHead -ne $originMainAtActivation) {
                throw "HEAD mismatch for equalsOriginMainAtActivation. expected=$originMainAtActivation actual=$CurrentHead branch=$CurrentBranch."
            }
        }
        default {
            throw "Unsupported lease headPolicy '$headPolicy'."
        }
    }
}

function Assert-ThresholdActionAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $LeaseLines,
        [Parameter(Mandatory = $true)]
        [string] $LeasePath,
        [Parameter(Mandatory = $true)]
        [ValidateSet("push", "pr", "merge", "release", "deploy")]
        [string] $Action
    )

    $forbiddenActions = @(Get-ThresholdLeaseList -Lines $LeaseLines -Name "forbiddenActions")
    $aliases = switch ($Action) {
        "push" { @("push", "push_to_upstream", "force_push") }
        "pr" { @("pr", "pull_request") }
        "merge" { @("merge") }
        "release" { @("release") }
        "deploy" { @("deploy") }
    }

    foreach ($alias in $aliases) {
        if ($forbiddenActions -contains $alias) {
            throw "Lease forbids action '$Action' via forbiddenActions entry '$alias'."
        }
    }

    if ($Action -eq "merge") {
        $mergeAllowed = Get-ThresholdLeaseBoolean -Lines $LeaseLines -Name "mergeAllowed" -LeasePath $LeasePath
        if (-not $mergeAllowed) {
            throw "Lease terminalBoundary.mergeAllowed is false."
        }
    }

    if ($Action -eq "pr") {
        $draftPrAllowed = Get-ThresholdLeaseBoolean -Lines $LeaseLines -Name "draftPrAllowed" -LeasePath $LeasePath
        if (-not $draftPrAllowed) {
            throw "Lease terminalBoundary.draftPrAllowed is false."
        }
    }
}

function Assert-ThresholdChangedPathsAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $LeaseLines,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ChangedPaths
    )

    $allowedPaths = @(Get-ThresholdLeaseList -Lines $LeaseLines -Name "allowedPaths")
    $forbiddenPaths = @(Get-ThresholdLeaseList -Lines $LeaseLines -Name "forbiddenPaths")

    foreach ($path in $ChangedPaths) {
        $isAllowed = $false
        foreach ($pattern in $allowedPaths) {
            if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
                $isAllowed = $true
                break
            }
        }
        if (-not $isAllowed) {
            throw "Changed path is outside lease allowlist: $path"
        }

        foreach ($pattern in $forbiddenPaths) {
            if (Test-ThresholdPathAgainstPattern -Path $path -Pattern $pattern) {
                throw "Changed path is forbidden by lease: $path"
            }
        }
    }
}
