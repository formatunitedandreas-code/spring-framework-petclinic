[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/lease-policy.ps1")

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    try {
        & $ScriptBlock
    }
    catch {
        Write-Host "passed=$Name"
        return
    }
    throw "Expected failure did not occur: $Name"
}

function Assert-DoesNotThrow {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    & $ScriptBlock
    Write-Host "passed=$Name"
}

function New-LeaseLines {
    param(
        [string] $HeadPolicy,
        [string] $StartHead,
        [string] $OriginMainAtActivation,
        [string] $MergeAllowed = "false",
        [string[]] $ForbiddenActions = @("release", "deploy")
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("leaseName: enforcement-canary")
    $lines.Add("branch: agent/enforcement-canary")
    $lines.Add("baseRef: HEAD")
    $lines.Add("startHead: $StartHead")
    $lines.Add("originMainAtActivation: $OriginMainAtActivation")
    $lines.Add("headPolicy: $HeadPolicy")
    $lines.Add("allowedPaths:")
    $lines.Add("  - src/main/**")
    $lines.Add("forbiddenPaths:")
    $lines.Add("  - secrets/**")
    $lines.Add("forbiddenActions:")
    foreach ($action in $ForbiddenActions) {
        $lines.Add("  - $action")
    }
    $lines.Add("terminalBoundary:")
    $lines.Add("  draftPrAllowed: true")
    $lines.Add("  mergeAllowed: $MergeAllowed")
    return @($lines.ToArray())
}

$originalLocation = Get-Location
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-governance-enforcement-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Set-Location $tempRoot
    & git init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed" }
    & git config user.email "threshold-canary@example.invalid"
    & git config user.name "Threshold Canary"
    Set-Content -Path "README.md" -Value "canary"
    & git add README.md
    & git commit -m "Initial canary commit" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
    $initialHead = (& git rev-parse HEAD).Trim()
    & git switch -c "agent/enforcement-canary" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "branch switch failed" }

    $passingLease = New-LeaseLines -HeadPolicy "equalsOriginMainAtActivation" -StartHead $initialHead -OriginMainAtActivation $initialHead -MergeAllowed "true"
    Assert-DoesNotThrow -Name "equalsOriginMainAtActivation accepts activation head" -ScriptBlock {
        Assert-ThresholdHeadPolicy -LeaseLines $passingLease -LeasePath "canary" -CurrentHead $initialHead -CurrentBranch "agent/enforcement-canary"
    }

    Set-Content -Path "README.md" -Value "canary drift"
    & git add README.md
    & git commit -m "Drift canary head" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "drift commit failed" }
    $driftHead = (& git rev-parse HEAD).Trim()

    $driftLease = New-LeaseLines -HeadPolicy "equalsOriginMainAtActivation" -StartHead $initialHead -OriginMainAtActivation $initialHead
    Assert-Throws -Name "equalsOriginMainAtActivation blocks base drift" -ScriptBlock {
        Assert-ThresholdHeadPolicy -LeaseLines $driftLease -LeasePath "canary" -CurrentHead $driftHead -CurrentBranch "agent/enforcement-canary"
    }

    $unknownPolicyLease = New-LeaseLines -HeadPolicy "unsupportedPolicy" -StartHead $initialHead -OriginMainAtActivation $initialHead
    Assert-Throws -Name "unknown headPolicy is fail closed" -ScriptBlock {
        Assert-ThresholdHeadPolicy -LeaseLines $unknownPolicyLease -LeasePath "canary" -CurrentHead $driftHead -CurrentBranch "agent/enforcement-canary"
    }

    $mergeDeniedLease = New-LeaseLines -HeadPolicy "descendantOfStartHead" -StartHead $initialHead -OriginMainAtActivation $initialHead -MergeAllowed "false"
    Assert-Throws -Name "mergeAllowed false blocks merge" -ScriptBlock {
        Assert-ThresholdActionAllowed -LeaseLines $mergeDeniedLease -LeasePath "canary" -Action "merge"
    }

    $mergeForbiddenLease = New-LeaseLines -HeadPolicy "descendantOfStartHead" -StartHead $initialHead -OriginMainAtActivation $initialHead -MergeAllowed "true" -ForbiddenActions @("merge")
    Assert-Throws -Name "forbiddenActions merge blocks merge" -ScriptBlock {
        Assert-ThresholdActionAllowed -LeaseLines $mergeForbiddenLease -LeasePath "canary" -Action "merge"
    }

    $mergeAllowedLease = New-LeaseLines -HeadPolicy "descendantOfStartHead" -StartHead $initialHead -OriginMainAtActivation $initialHead -MergeAllowed "true"
    Assert-DoesNotThrow -Name "mergeAllowed true permits merge policy check" -ScriptBlock {
        Assert-ThresholdActionAllowed -LeaseLines $mergeAllowedLease -LeasePath "canary" -Action "merge"
    }

    if (-not (Test-ThresholdGovernancePath -Path "threshold/scripts/preflight.ps1")) {
        throw "Expected threshold/scripts/preflight.ps1 to be a governance path."
    }
    if (-not (Test-ThresholdGovernancePath -Path "threshold/discovery-canaries/fixtures/src/main/java/org/springframework/samples/petclinic/web/CanaryAnnotationController.java")) {
        throw "Expected threshold discovery canary fixtures to be governance evidence paths."
    }
    if (Test-ThresholdGovernancePath -Path "src/main/java/App.java") {
        throw "Did not expect src/main/java/App.java to be a governance path."
    }
    Write-Host "passed=governance path classification"

    Write-Host "thresholdGovernanceEnforcement=passed"
}
finally {
    Set-Location $originalLocation
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
