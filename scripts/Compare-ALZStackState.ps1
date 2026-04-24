<#
.SYNOPSIS
    ALZ State Auditor - REST API Edition.
.DESCRIPTION
    Bypasses Get-AzPolicy cmdlets to query the ARM REST API directly.
    This guarantees accurate JSON retrieval without PowerShell parsing errors.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantIntRootMgId,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "ALZ-State-REST-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
)

$ErrorActionPreference = "Stop"

# 1. Define the ALZ Stack Architecture
$mgStacks = @(
    @{ Scope = "mg"; MgId = $TenantIntRootMgId; Name = "$TenantIntRootMgId-governance-int-root" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-platform" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones-corp" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-landingzones-online" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-sandbox" }
    @{ Scope = "mg"; MgId = "alz"; Name = "alz-governance-decommissioned" }
)

$subStacks = @(
    @{ Scope = "sub"; Name = "alz-core-logging" }
    @{ Scope = "sub"; Name = "alz-networking-hub" }
)

# 2. REST API Helper Function
function Get-ArmResourceState {
    param([string]$ResourceId)
    
    $apiVersion = "2021-06-01" 
    if ($ResourceId -match "/policyAssignments/") { $apiVersion = "2024-04-01" }

    try {
        $response = Invoke-AzRestMethod -Method GET -Path "$ResourceId`?api-version=$apiVersion"
        
        if ($response.StatusCode -eq 200) {
            # THE FIX: Safely attempt JSON conversion
            try {
                return $response.Content | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                # If ConvertFrom-Json fails with the '@' error, it means 
                # PowerShell already parsed it natively! Just return the content.
                return $response.Content
            }
        }
        else {
            return @{ Error = "HTTP $($response.StatusCode)" }
        }
    }
    catch {
        return @{ Error = "REST Call Failed: $($_.Exception.Message)" }
    }
}

# 3. Main Execution
Write-Host "--- ALZ State Export Started (REST API Mode) ---" -ForegroundColor Cyan
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$results = @{
    Timestamp = (Get-Date -Format "o")
    Stacks    = @()
}

foreach ($s in ($mgStacks + $subStacks)) {
    Write-Host "Auditing Stack: $($s.Name)" -ForegroundColor Yellow
    try {
        if ($s.Scope -eq "mg") {
            $stack = Get-AzManagementGroupDeploymentStack -ManagementGroupId $s.MgId -Name $s.Name
        }
        else {
            $stack = Get-AzSubscriptionDeploymentStack -Name $s.Name
        }

        $stackSnapshots = @()
        $resourceIds = $stack.Resources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } }
        
        foreach ($rid in $resourceIds) {
            $snapshot = @{ ResourceId = $rid; Type = "unknown" }
            
            # Identify Type
            if ($rid -match "/policyAssignments/") { $snapshot.Type = "policyAssignment" }
            elseif ($rid -match "/policyDefinitions/") { $snapshot.Type = "policyDefinition" }
            elseif ($rid -match "/policySetDefinitions/") { $snapshot.Type = "policySetDefinition" }

            # Fetch via REST
            $armData = Get-ArmResourceState -ResourceId $rid

            if ($armData.Error) {
                $snapshot.Error = $armData.Error
            }
            else {
                $snapshot.DisplayName = $armData.properties.displayName
                
                # Extract specifics based on type
                if ($snapshot.Type -eq "policyAssignment") {
                    $snapshot.Parameters = $armData.properties.parameters
                    $snapshot.EnforcementMode = $armData.properties.enforcementMode
                }
                elseif ($snapshot.Type -eq "policySetDefinition") {
                    $snapshot.PolicyCount = @($armData.properties.policyDefinitions).Count
                    $snapshot.Definitions = $armData.properties.policyDefinitions | Select-Object policyDefinitionId
                }
                elseif ($snapshot.Type -eq "policyDefinition") {
                    # Create a reliable hash of the rule
                    $ruleJson = $armData.properties.policyRule | ConvertTo-Json -Depth 20 -Compress
                    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ruleJson))
                    $snapshot.PolicyRuleHash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").Substring(0, 16)
                }
            }
            $stackSnapshots += $snapshot
        }

        $results.Stacks += @{
            StackName         = $stack.Name
            Scope             = $s.Scope
            ProvisioningState = $stack.ProvisioningState
            ResourceSnapshots = $stackSnapshots
        }
    }
    catch {
        Write-Host "  [!] Error accessing stack: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 4. Final Save
$results | ConvertTo-Json -Depth 100 | Out-File -FilePath $OutputFile -Encoding utf8
Write-Host "Export complete! File saved to: $OutputFile" -ForegroundColor Green