<#
.SYNOPSIS
    ALZ State Auditor - Final Thesis-Grade Edition.
.DESCRIPTION
    Använder ARM REST API för att hämta den absoluta sanningen om ALZ-policys.
    Fångar hela objekt (inte bara ID:n) för att möjliggöra djupgående diff-analys.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantIntRootMgId,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "ALZ-FullState-Baseline-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
)

$ErrorActionPreference = "Stop"

# 1. Definiera ALZ Stack-arkitekturen (Hela hierarkin)
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

# 2. REST API Helper - Hämtar rå JSON direkt från Azure
function Get-ArmResourceState {
    param([string]$ResourceId)
    
    # API-versioner som stödjer alla moderna policy-funktioner
    $apiVersion = "2021-06-01" 
    if ($ResourceId -match "/policyAssignments/") { $apiVersion = "2024-04-01" }

    try {
        $response = Invoke-AzRestMethod -Method GET -Path "$ResourceId`?api-version=$apiVersion"
        if ($response.StatusCode -eq 200) {
            return $response.Content | ConvertFrom-Json
        }
        else {
            return @{ Error = "HTTP $($response.StatusCode): $($response.Content)" }
        }
    }
    catch {
        return @{ Error = "REST Call Failed: $($_.Exception.Message)" }
    }
}

# 3. Exekvering
Write-Host "--- STARTAR FULLSTÄNDIG EXPORT (ALZ DEEP STATE) ---" -ForegroundColor Cyan
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$results = @{
    Timestamp = (Get-Date -Format "o")
    Metadata  = @{
        RootMg       = $TenantIntRootMgId
        Subscription = $SubscriptionId
    }
    Stacks    = @()
}

foreach ($s in ($mgStacks + $subStacks)) {
    Write-Host "Inventerar Stack: $($s.Name)..." -ForegroundColor Yellow
    try {
        if ($s.Scope -eq "mg") {
            $stack = Get-AzManagementGroupDeploymentStack -ManagementGroupId $s.MgId -Name $s.Name -ErrorAction SilentlyContinue
        }
        else {
            $stack = Get-AzSubscriptionDeploymentStack -Name $s.Name -ErrorAction SilentlyContinue
        }

        if (-not $stack) {
            Write-Host "  [!] Stacken hittades inte, hoppar över." -ForegroundColor Gray
            continue
        }

        $resourceSnapshots = @()
        $resourceIds = $stack.Resources | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Id } }
        
        foreach ($rid in $resourceIds) {
            # Filtrera för att bara hämta Policy-relaterade resurser (hjärtat i ALZ)
            if ($rid -notmatch "Microsoft.Authorization") { continue }

            $snapshot = @{ ResourceId = $rid; Type = "unknown" }
            
            # Identifiera typ för logikval
            if ($rid -match "/policyAssignments/") { $snapshot.Type = "policyAssignment" }
            elseif ($rid -match "/policyDefinitions/") { $snapshot.Type = "policyDefinition" }
            elseif ($rid -match "/policySetDefinitions/") { $snapshot.Type = "policySetDefinition" }

            # Hämta den djupa datan via REST
            $armData = Get-ArmResourceState -ResourceId $rid

            if ($armData.Error) {
                $snapshot.Error = $armData.Error
            }
            else {
                $snapshot.DisplayName = $armData.properties.displayName
                
                # --- POLICY ASSIGNMENTS: Fånga parametrar (här bor "deny"-buggen) ---
                if ($snapshot.Type -eq "policyAssignment") {
                    $snapshot.Parameters = $armData.properties.parameters
                    $snapshot.EnforcementMode = $armData.properties.enforcementMode
                    $snapshot.PolicyDefinitionId = $armData.properties.policyDefinitionId
                }
                
                # --- POLICY SETS (Initiativ): Fånga hela strukturen ---
                elseif ($snapshot.Type -eq "policySetDefinition") {
                    $snapshot.Parameters = $armData.properties.parameters
                    # Vi sparar HELA definitionen för att se om underliggande policys ändras
                    $snapshot.FullDefinitions = $armData.properties.policyDefinitions 
                }
                
                # --- POLICY DEFINITIONS: Fånga själva regeln och skapa hash ---
                elseif ($snapshot.Type -eq "policyDefinition") {
                    $snapshot.RawPolicyRule = $armData.properties.policyRule
                    
                    # Skapa en hash för att snabbt kunna jämföra stora mängder regler
                    $ruleJson = $armData.properties.policyRule | ConvertTo-Json -Depth 20 -Compress
                    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ruleJson))
                    $snapshot.PolicyRuleHash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").Substring(0, 16)
                }
            }
            $resourceSnapshots += $snapshot
        }

        $results.Stacks += @{
            StackName         = $stack.Name
            Scope             = $s.Scope
            ProvisioningState = $stack.ProvisioningState
            ResourceCount     = $resourceSnapshots.Count
            ResourceSnapshots = $resourceSnapshots
        }
    }
    catch {
        Write-Host "  [!] Fel vid åtkomst av stack: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 4. Spara till fil
# Vi använder Depth 100 för att säkerställa att ingen data trunkeras till @{...}
$results | ConvertTo-Json -Depth 100 | Out-File -FilePath $OutputFile -Encoding utf8

Write-Host "`nKLART!" -ForegroundColor Green
Write-Host "Din baseline har sparats till: $OutputFile" -ForegroundColor White
Write-Host "Antal stackar analyserade: $($results.Stacks.Count)" -ForegroundColor White