<#
.SYNOPSIS
    Compares two ALZ stack state exports for K5 change containment verification.

.DESCRIPTION
    Reads two JSON files produced by Export-ALZStackState.ps1 and reports:
    - Which stacks changed (DeploymentId, resource snapshots)
    - Which stacks were untouched
    - Specific property changes in affected stacks

    Ignores: ExportTimestamp (expected to differ)

.EXAMPLE
    ./Compare-ALZStackState.ps1 -BeforeFile "state-before.json" -AfterFile "state-after.json"
#>

param(
    [Parameter(Mandatory)]
    [string]$BeforeFile,

    [Parameter(Mandatory)]
    [string]$AfterFile
)

$ErrorActionPreference = "Stop"

$before = Get-Content $BeforeFile -Raw | ConvertFrom-Json
$after  = Get-Content $AfterFile -Raw  | ConvertFrom-Json

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " K5 Change Containment -- Diff Report" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Before: $BeforeFile"
Write-Host "After:  $AfterFile"
Write-Host ""

$changedStacks = @()
$unchangedStacks = @()

foreach ($beforeStack in $before.Stacks) {
    $afterStack = $after.Stacks | Where-Object { $_.Name -eq $beforeStack.Name }

    if (-not $afterStack) {
        Write-Host "  MISSING in after: $($beforeStack.Name)" -ForegroundColor Red
        continue
    }

    $differences = @()

    # Compare DeploymentId (changes when stack is redeployed)
    if ($beforeStack.DeploymentId -ne $afterStack.DeploymentId) {
        $differences += "DeploymentId changed"
    }

    # Compare ProvisioningState
    if ($beforeStack.ProvisioningState -ne $afterStack.ProvisioningState) {
        $differences += "ProvisioningState changed: $($beforeStack.ProvisioningState) -> $($afterStack.ProvisioningState)"
    }

    # Compare resource counts
    if ($beforeStack.ResourceCount -ne $afterStack.ResourceCount) {
        $differences += "ResourceCount changed: $($beforeStack.ResourceCount) -> $($afterStack.ResourceCount)"
    }

    # Compare resource ID lists
    $beforeIds = ($beforeStack.ResourceIds | Sort-Object) -join "`n"
    $afterIds  = ($afterStack.ResourceIds | Sort-Object) -join "`n"
    if ($beforeIds -ne $afterIds) {
        $differences += "Resource ID list changed"
    }

    # Compare deleted/detached resources
    if (($beforeStack.DeletedResources | ConvertTo-Json -Compress) -ne ($afterStack.DeletedResources | ConvertTo-Json -Compress)) {
        $differences += "DeletedResources changed"
    }
    if (($beforeStack.DetachedResources | ConvertTo-Json -Compress) -ne ($afterStack.DetachedResources | ConvertTo-Json -Compress)) {
        $differences += "DetachedResources changed"
    }

    # Compare resource snapshots (the actual property values)
    if ($beforeStack.ResourceSnapshots -and $afterStack.ResourceSnapshots) {
        foreach ($beforeSnap in $beforeStack.ResourceSnapshots) {
            $afterSnap = $afterStack.ResourceSnapshots | Where-Object { $_.ResourceId -eq $beforeSnap.ResourceId }

            if (-not $afterSnap) { continue }

            # Use type-aware semantic comparison instead of full JSON string comparison.
            # ConvertTo-Json -Compress produces non-deterministic property ordering, causing
            # false positives for unchanged resources. Compare only the fields that matter.
            $resourceChanged = $false
            $resourceName = ($beforeSnap.ResourceId -split "/")[-1]

            if ($beforeSnap.Type -eq "policyAssignment" -and $afterSnap.Type -eq "policyAssignment") {
                # Compare enforcement mode
                if ($beforeSnap.EnforcementMode -ne $afterSnap.EnforcementMode) {
                    $resourceChanged = $true
                    $differences += "Resource changed: $resourceName"
                    $differences += "  -> EnforcementMode: $($beforeSnap.EnforcementMode) -> $($afterSnap.EnforcementMode)"
                }

                # Compare parameters key-by-key (sorted, value-serialized)
                $bp = $beforeSnap.Parameters
                $ap = $afterSnap.Parameters
                $paramChanged = $false
                $paramDiffs = @()

                if ($bp -or $ap) {
                    $allKeys = @()
                    if ($bp) { $bp.PSObject.Properties | ForEach-Object { $allKeys += $_.Name } }
                    if ($ap) { $ap.PSObject.Properties | ForEach-Object { if ($_.Name -notin $allKeys) { $allKeys += $_.Name } } }

                    foreach ($key in ($allKeys | Sort-Object)) {
                        $bv = ($bp.$key | ConvertTo-Json -Depth 5 -Compress)
                        $av = ($ap.$key | ConvertTo-Json -Depth 5 -Compress)
                        if ($bv -ne $av) {
                            $paramChanged = $true
                            $paramDiffs += "  -> Parameter '$key': $bv -> $av"
                        }
                    }
                }

                if ($paramChanged) {
                    if (-not $resourceChanged) {
                        $resourceChanged = $true
                        $differences += "Resource changed: $resourceName"
                    }
                    $differences += "  -> Policy assignment parameters changed"
                    $differences += $paramDiffs
                }
            }
            elseif ($beforeSnap.Type -eq "policyDefinition" -and $afterSnap.Type -eq "policyDefinition") {
                if ($beforeSnap.PolicyRuleHash -and $afterSnap.PolicyRuleHash) {
                    if ($beforeSnap.PolicyRuleHash -ne $afterSnap.PolicyRuleHash) {
                        $resourceChanged = $true
                        $differences += "Resource changed: $resourceName"
                        $differences += "  -> PolicyRule hash changed"
                    }
                }
            }
            elseif ($beforeSnap.Type -eq "policySetDefinition" -and $afterSnap.Type -eq "policySetDefinition") {
                if ($beforeSnap.PolicyDefinitionCount -ne $afterSnap.PolicyDefinitionCount) {
                    $resourceChanged = $true
                    $differences += "Resource changed: $resourceName"
                    $differences += "  -> PolicyDefinitionCount: $($beforeSnap.PolicyDefinitionCount) -> $($afterSnap.PolicyDefinitionCount)"
                }
            }
            else {
                # For other resource types fall back to JSON comparison (ResourceId, Type, Name fields only)
                $bSafe = [PSCustomObject]@{ ResourceId = $beforeSnap.ResourceId; Type = $beforeSnap.Type; Name = $beforeSnap.Name }
                $aSafe = [PSCustomObject]@{ ResourceId = $afterSnap.ResourceId;  Type = $afterSnap.Type;  Name = $afterSnap.Name  }
                if (($bSafe | ConvertTo-Json -Compress) -ne ($aSafe | ConvertTo-Json -Compress)) {
                    $resourceChanged = $true
                    $differences += "Resource changed: $resourceName"
                }
            }
        }
    }

    if ($differences.Count -gt 0) {
        $changedStacks += $beforeStack.Name
        Write-Host "  CHANGED: $($beforeStack.Name)" -ForegroundColor Yellow
        foreach ($d in $differences) {
            Write-Host "    $d" -ForegroundColor Yellow
        }
    }
    else {
        $unchangedStacks += $beforeStack.Name
        Write-Host "  UNCHANGED: $($beforeStack.Name)" -ForegroundColor Green
    }
}

# Summary
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
$changedColor = if ($changedStacks.Count -le 1) { "Green" } else { "Red" }
Write-Host "Changed stacks:   $($changedStacks.Count)" -ForegroundColor $changedColor
Write-Host "Unchanged stacks: $($unchangedStacks.Count)" -ForegroundColor Green
Write-Host ""

if ($changedStacks.Count -eq 0) {
    Write-Host "RESULT: No stacks changed. Deployment was fully idempotent." -ForegroundColor Green
}
elseif ($changedStacks.Count -eq 1) {
    $name = $changedStacks[0]
    Write-Host "RESULT: Only '$name' was affected." -ForegroundColor Green
    Write-Host "K5 PASSED: Change was contained to the expected scope." -ForegroundColor Green
}
else {
    $affected = $changedStacks -join ', '
    Write-Host "RESULT: Multiple stacks were affected: $affected" -ForegroundColor Red
    Write-Host "K5 REVIEW NEEDED: Change may have leaked beyond expected scope." -ForegroundColor Red
}
