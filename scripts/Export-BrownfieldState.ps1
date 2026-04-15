#Requires -Version 7
<#
.SYNOPSIS
    Exporterar Azure Landing Zone-styrning och infrastrukturstate som JSON.

.DESCRIPTION
    Skannar en befintlig (portaldriftsatt) Azure Landing Zone-tenant och exporterar dess
    styrnings- och infrastrukturstate som JSON. Resultatet används av Compare-BrownfieldState.ps1
    för att analysera befintlig konfiguration inför in-place-takeover med engine.

    Nyckelskillnad från Export-ALZStackState.ps1: detta script frågar resurser direkt
    eftersom en portaldriftsatt ALZ saknar Deployment Stacks.

    Skrivskyddat. Inga ändringar görs i tenanten.

.PARAMETER OutputFile
    Sökväg för JSON-exportfilen.

.PARAMETER RootManagementGroupId
    Det intermediära rot-MG:ts ID (t.ex. 'alz').
    Auto-detekteras från tenanten om det utelämnas.

.PARAMETER TenantId
    Azure tenant-ID. Auto-detekteras från az account show om det utelämnas.

.PARAMETER PlatformSubscriptionIds
    Prenumerations-ID:n att skanna efter infrastrukturresurser (logging, nätverk osv.).
    Om det utelämnas försöker scriptet hitta prenumerationer under plattforms-MG:na
    (management, connectivity, identity, security, eller platform).

.EXAMPLE
    ./Export-BrownfieldState.ps1 -OutputFile "brownfield-state.json"

.EXAMPLE
    ./Export-BrownfieldState.ps1 `
        -OutputFile "brownfield-state.json" `
        -RootManagementGroupId "alz" `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -PlatformSubscriptionIds @("sub-id-1", "sub-id-2")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputFile,

    [string]$RootManagementGroupId = '',

    [string]$TenantId = '',

    [string[]]$PlatformSubscriptionIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step  ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" }          else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info  ($msg) { if ($NoColor) { Write-Host "[INFO]  $msg" }           else { Write-Host "`e[36m[INFO]`e[0m  $msg" } }
function Write-Ok    ($msg) { if ($NoColor) { Write-Host "[OK]    $msg" }           else { Write-Host "`e[32m[OK]`e[0m    $msg" } }
function Write-Warn  ($msg) { if ($NoColor) { Write-Host "[WARN]  $msg" }           else { Write-Host "`e[33m[WARN]`e[0m  $msg" } }
function Write-Fail  ($msg) { if ($NoColor) { Write-Host "[SKIP]  $msg" }           else { Write-Host "`e[31m[SKIP]`e[0m  $msg" } }

# Välkända ALZ intermediära rot-MG:ts barnnamn för auto-detektering
$AlzWellKnownChildMgs = @('platform', 'landingzones', 'sandbox', 'decommissioned')

# Plattforms-MG-namn för prenumerationsupptäckt
$AlzPlatformMgs = @('management', 'connectivity', 'identity', 'security')
$AlzPlatformFallbackMg = 'platform'

# ============================================================
# Hjälpfunktion: beräkna SHA256-hash (de 16 första hex-tecknen)
# ============================================================
function Get-SHA256Short ([string]$InputString) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
}

# ============================================================
# Hjälpfunktion: sortera objektegenskaper alfabetiskt rekursivt
# för deterministisk JSON-serialisering vid hashning av policyregler.
# Arrayer behåller elementordning; bara egenskapsnamn inom objekt sorteras.
# ============================================================
function ConvertTo-SortedObject ($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IList]) {
        return @($obj | ForEach-Object { ConvertTo-SortedObject $_ })
    }
    if ($obj -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $obj.Keys | Sort-Object | ForEach-Object { $ordered[$_] = ConvertTo-SortedObject $obj[$_] }
        return [PSCustomObject]$ordered
    }
    if ($obj -is [PSCustomObject]) {
        $ordered = [ordered]@{}
        $obj.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object | ForEach-Object { $ordered[$_] = ConvertTo-SortedObject $obj.$_ }
        return [PSCustomObject]$ordered
    }
    return $obj
}

# ============================================================
# Hjälpfunktion: hämta egenskapsvärde säkert från PSObject utan
# att kasta fel i strict mode. Provar varje namn i ordning och
# returnerar första icke-null-värde.
# ============================================================
function Get-PropSafe ($Obj, [string[]]$Names) {
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

# ============================================================
# Hjälpfunktion: normalisera MG-namn för välkända namn-jämförelser
#   - tar bort ALZ-prefix (skiftlägesokänsligt)
#   - konverterar till gemener
#   - normaliserar pluralvarianter (sandboxes -> sandbox)
# ============================================================
function Get-NormalizedMgName ([string]$Name) {
    $n = $Name -replace '(?i)^alz-', ''
    $n = $n.ToLower()
    if ($n -eq 'sandboxes') { $n = 'sandbox' }
    return $n
}

# ============================================================
# Steg 1: Lös upp TenantId
# ============================================================
function Resolve-TenantId {
    Write-Step 'Löser upp tenant-identitet'

    if ($Script:TenantId -eq '') {
        $account = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($account) {
            $Script:TenantId = $account.tenantId
            Write-Info "Tenant-ID auto-detekterat: $Script:TenantId"
        }
    }

    if ($Script:TenantId -eq '') {
        Write-Error 'Kunde inte fastställa TenantId. Ange -TenantId explicit eller logga in med az login.'
    }

    Write-Info "Tenant: $Script:TenantId"
}

# ============================================================
# Steg 2: Hitta ALZ intermediärt rot-MG
# ============================================================
function Resolve-RootManagementGroup {
    Write-Step 'Löser upp ALZ intermediärt rot-MG'

    if ($Script:RootManagementGroupId -ne '') {
        Write-Info "Använder angivet rot-MG: $Script:RootManagementGroupId"
        return
    }

    Write-Info 'Skannar tenant-root för ALZ intermediärt rot-MG...'

    $tenantRootMgs = Get-AzManagementGroup -ErrorAction SilentlyContinue
    if (-not $tenantRootMgs) {
        Write-Error 'Kunde inte hämta management groups. Kontrollera att du har Reader-åtkomst på tenant-root.'
    }

    foreach ($mg in $tenantRootMgs) {
        $expanded = Get-AzManagementGroup -GroupId $mg.Name -Expand -ErrorAction SilentlyContinue
        if (-not $expanded) { continue }

        $childNames         = @($expanded.Children | ForEach-Object { $_.Name })
        $normalizedChildren = $childNames | ForEach-Object { Get-NormalizedMgName $_ }
        $matchedMgs         = @($normalizedChildren | Where-Object { $AlzWellKnownChildMgs -contains $_ })

        if ($matchedMgs.Count -ge 2) {
            $Script:RootManagementGroupId = $mg.Name
            Write-Info "ALZ intermediärt rot-MG detekterat: $Script:RootManagementGroupId (barn: $($childNames -join ', '))"
            return
        }
    }

    Write-Warn 'Kunde inte auto-detektera ALZ intermediärt rot-MG. Ange -RootManagementGroupId explicit.'
    Write-Warn 'Fortsätter utan rot-MG — governance-scopes kommer att vara tomma.'
}

# ============================================================
# Steg 3: Bygg MG-hierarki rekursivt
# ============================================================
function Get-MgHierarchy ([string]$GroupId) {
    $mg = Get-AzManagementGroup -GroupId $GroupId -Expand -Recurse -ErrorAction SilentlyContinue
    if (-not $mg) {
        Write-Warn "  Kunde inte expandera MG '$GroupId' — hoppar över."
        return $null
    }

    function ConvertTo-Node ($mgObj) {
        $parentId = ''
        if ($mgObj.PSObject.Properties['Details'] -and $mgObj.Details.Parent) {
            $parentId = $mgObj.Details.Parent.Id
        } elseif ($mgObj.PSObject.Properties['ParentId']) {
            $parentId = $mgObj.ParentId
        }
        $node = @{
            Name        = $mgObj.Name
            DisplayName = $mgObj.DisplayName
            ParentId    = $parentId
            Children    = @()
        }
        if ($mgObj.Children) {
            foreach ($child in $mgObj.Children) {
                # Hoppa över prenumerationer — deras Type är '/subscriptions'
                if ($child.Type -ieq '/subscriptions') { continue }
                $node.Children += ConvertTo-Node $child
            }
        }
        return $node
    }

    return ConvertTo-Node $mg
}

# ============================================================
# Steg 4: Samla alla MG-ID:n från hierarkin (platt lista)
# ============================================================
function Get-AllMgIds ([hashtable]$HierarchyNode) {
    $ids = @($HierarchyNode.Name)
    foreach ($child in $HierarchyNode.Children) {
        $ids += Get-AllMgIds -HierarchyNode $child
    }
    return $ids
}

# ============================================================
# Steg 5: Hitta plattformsprenumerationer
# ============================================================
function Resolve-PlatformSubscriptions {
    Write-Step 'Löser upp plattformsprenumerationer'

    if ($Script:PlatformSubscriptionIds.Count -gt 0) {
        Write-Info "Använder $($Script:PlatformSubscriptionIds.Count) angivna plattformsprenumeration(er)."
        return
    }

    Write-Info 'Försöker hitta plattformsprenumerationer från MG-hierarkin...'

    $found = @()

    # Bygg normaliserat namn → faktiskt MG-ID för att hantera ALZ-prefix
    $normalizedToActual = @{}
    if ($Script:ActualMgIds) {
        foreach ($actualId in $Script:ActualMgIds) {
            $normalizedToActual[(Get-NormalizedMgName $actualId)] = $actualId
        }
    }

    foreach ($mgName in $AlzPlatformMgs) {
        $actualMgId = if ($normalizedToActual.ContainsKey($mgName)) {
            $normalizedToActual[$mgName]
        } else {
            $mgName
        }

        $response = Invoke-AzRestMethod `
            -Path "/providers/Microsoft.Management/managementGroups/$actualMgId/subscriptions?api-version=2020-05-01" `
            -Method GET `
            -ErrorAction SilentlyContinue

        if ($response -and $response.StatusCode -eq 200) {
            $subs = ($response.Content | ConvertFrom-Json).value
            foreach ($sub in $subs) {
                if ($sub.name -notin $found) {
                    $found += $sub.name
                    Write-Info "  Hittade prenumeration $($sub.name) under MG '$actualMgId'"
                }
            }
        }
    }

    # Fallback till generiskt platform-MG
    if ($found.Count -eq 0) {
        $actualFallbackId = if ($normalizedToActual.ContainsKey($AlzPlatformFallbackMg)) {
            $normalizedToActual[$AlzPlatformFallbackMg]
        } else {
            $AlzPlatformFallbackMg
        }

        $response = Invoke-AzRestMethod `
            -Path "/providers/Microsoft.Management/managementGroups/$actualFallbackId/subscriptions?api-version=2020-05-01" `
            -Method GET `
            -ErrorAction SilentlyContinue

        if ($response -and $response.StatusCode -eq 200) {
            $subs = ($response.Content | ConvertFrom-Json).value
            foreach ($sub in $subs) {
                if ($sub.name -notin $found) {
                    $found += $sub.name
                    Write-Info "  Hittade prenumeration $($sub.name) under MG '$actualFallbackId' (fallback)"
                }
            }
        }
    }

    if ($found.Count -eq 0) {
        $Script:Warnings += 'Kunde inte hitta några plattformsprenumerationer. Infrastruktur-discovery hoppas över. Ange -PlatformSubscriptionIds explicit.'
        Write-Warn 'Inga plattformsprenumerationer hittades — infrastruktur-scopes hoppas över.'
    }

    $Script:PlatformSubscriptionIds = $found
}

# ============================================================
# Steg 6: Samla governance-resurser för ett management group
# ============================================================
function Get-GovernanceScope ([string]$MgId, [string]$ScopeName) {
    Write-Info "  Skannar governance-scope: $ScopeName (MG: $MgId)"

    $scope     = "/providers/Microsoft.Management/managementGroups/$MgId"
    $resources = @{
        PolicyDefinitions    = @()
        PolicySetDefinitions = @()
        PolicyAssignments    = @()
        RoleDefinitions      = @()
        RoleAssignments      = @()
    }

    # --- Anpassade policydefinitioner ---
    # Slå in i @() så att ett enda resultat alltid är array (undviker .Count-problem i strict mode)
    $defs = @(Get-AzPolicyDefinition -ManagementGroupName $MgId -Custom -ErrorAction SilentlyContinue)
    foreach ($def in $defs) {
        $rid = Get-PropSafe $def 'ResourceId', 'PolicyDefinitionId', 'Id'
        if (-not $rid) { continue }
        if ($rid -inotmatch "managementGroups/$MgId/") { continue }

        try {
            $ruleJson = (ConvertTo-SortedObject (Get-PropSafe $def 'PolicyRule', 'Properties')) | ConvertTo-Json -Depth 20 -Compress
            $ruleJson = $ruleJson -replace '\[{2,}', '['  # normalisera ARM-escaping: [[ eller [[[ (nästlade DINE-templates) → [
            $hash     = Get-SHA256Short $ruleJson
        }
        catch {
            $hash = '(hash-error)'
        }

        $resources.PolicyDefinitions += @{
            ResourceId     = $rid
            Type           = 'policyDefinition'
            Name           = $def.Name
            DisplayName    = (Get-PropSafe $def 'DisplayName')
            Version        = if ($def.properties -and $def.properties.metadata -and $def.properties.metadata.PSObject.Properties['version']) { $def.properties.metadata.version } else { (Get-PropSafe $def 'Version') }
            PolicyRuleHash = $hash
            PolicyRule     = (Get-PropSafe $def 'PolicyRule', 'Properties')
            Metadata       = (Get-PropSafe $def 'Metadata')
            Scope          = $scope
        }
    }
    if ($defs.Count -gt 0) { Write-Info "    PolicyDefinitions: $($resources.PolicyDefinitions.Count)" }

    # --- Anpassade policyuppsättningsdefinitioner (initiativ) ---
    $sets = @(Get-AzPolicySetDefinition -ManagementGroupName $MgId -Custom -ErrorAction SilentlyContinue)
    foreach ($set in $sets) {
        $rid = Get-PropSafe $set 'ResourceId', 'PolicySetDefinitionId', 'Id'
        if (-not $rid) { continue }
        if ($rid -inotmatch "managementGroups/$MgId/") { continue }

        $defCount  = 0
        $polDefIds = @()
        try {
            $polDefs      = Get-PropSafe $set 'PolicyDefinition', 'PolicyDefinitions'
            $polDefArray  = if ($polDefs -is [string]) { @($polDefs | ConvertFrom-Json) }
                            elseif ($polDefs)           { @($polDefs) }
                            else                        { @() }
            $defCount     = $polDefArray.Count
            $polDefIds    = @($polDefArray | ForEach-Object {
                $id = Get-PropSafe $_ 'policyDefinitionId', 'PolicyDefinitionId'
                if ($id) { $id }
            } | Where-Object { $_ })
        }
        catch {
            $defCount  = 0
            $polDefIds = @()
        }

        $resources.PolicySetDefinitions += @{
            ResourceId            = $rid
            Type                  = 'policySetDefinition'
            Name                  = $set.Name
            DisplayName           = (Get-PropSafe $set 'DisplayName')
            PolicyDefinitionCount = $defCount
            PolicyDefinitions     = $polDefIds
            Scope                 = $scope
        }
    }
    if ($sets.Count -gt 0) { Write-Info "    PolicySetDefinitions: $($resources.PolicySetDefinitions.Count)" }

    # --- Policytilldelningar ---
    # Komplettera Get-AzPolicyAssignment med direkt REST-anrop för att fånga identity.principalId,
    # som Az.Resources 7.x inte alltid exponerar på returnerade PS-objekt.
    $restIdentityMap = @{}
    $restPaResponse = Invoke-AzRestMethod `
        -Path "$scope/providers/Microsoft.Authorization/policyAssignments?`$filter=atScope()&api-version=2024-04-01" `
        -Method GET -ErrorAction SilentlyContinue
    if ($restPaResponse -and $restPaResponse.StatusCode -eq 200) {
        $restPaData = $restPaResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($restPaData -and $restPaData.PSObject.Properties['value']) {
            foreach ($rpa in @($restPaData.value)) {
                if ($rpa.PSObject.Properties['identity'] -and $rpa.identity -and
                    $rpa.identity.PSObject.Properties['principalId'] -and $rpa.identity.principalId) {
                    $restIdentityMap[$rpa.id.ToLower()] = @{
                        Type        = if ($rpa.identity.PSObject.Properties['type']) { $rpa.identity.type } else { 'SystemAssigned' }
                        PrincipalId = $rpa.identity.principalId
                    }
                }
            }
        }
    }

    $assignments = @(Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue)
    foreach ($a in $assignments) {
        $aScope = Get-PropSafe $a 'Scope'
        if (-not $aScope) {
            $props = Get-PropSafe $a 'Properties'
            if ($props) { $aScope = $props.scope }
        }
        if ($aScope -and ($aScope -ine $scope)) { continue }

        $params = $null
        try {
            $rawParams = Get-PropSafe $a 'Parameter', 'Parameters'
            $params = if ($rawParams -is [string]) { $rawParams | ConvertFrom-Json }
                      else { $rawParams | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
        }
        catch { }

        $rid = Get-PropSafe $a 'ResourceId', 'PolicyAssignmentId', 'Id'

        # Bygg identitet: föredra REST API-kartan (auktoritativ), faller tillbaka på PS-objekt
        $identity = $null
        $restIdEntry = if ($rid) { $restIdentityMap[$rid.ToLower()] } else { $null }
        if ($restIdEntry) {
            $identity = $restIdEntry
        } else {
            $aIdentity = Get-PropSafe $a 'Identity'
            if ($aIdentity) {
                $identity = @{
                    Type        = (Get-PropSafe $aIdentity 'Type')
                    PrincipalId = (Get-PropSafe $aIdentity 'PrincipalId')
                }
            }
        }

        $resources.PolicyAssignments += @{
            ResourceId                 = $rid
            Type                       = 'policyAssignment'
            DisplayName                = (Get-PropSafe $a 'DisplayName')
            PolicyDefinitionId         = (Get-PropSafe $a 'PolicyDefinitionId')
            Parameters                 = $params
            EnforcementMode            = (Get-PropSafe $a 'EnforcementMode')
            Identity                   = $identity
            ManagedIdentityPrincipalId = if ($identity -and $identity.Type -eq 'SystemAssigned') { $identity.PrincipalId } else { $null }
            Scope                      = $scope
        }
    }
    if ($assignments.Count -gt 0) { Write-Info "    PolicyAssignments: $($resources.PolicyAssignments.Count)" }

    # --- Anpassade rolldefinitioner ---
    $roles = Get-AzRoleDefinition -Custom -ErrorAction SilentlyContinue |
        Where-Object { $_.AssignableScopes -contains $scope }
    if ($roles) {
        foreach ($role in $roles) {
            $resources.RoleDefinitions += @{
                ResourceId       = $role.Id
                Type             = 'roleDefinition'
                Name             = $role.Id
                RoleName         = $role.Name
                Permissions      = $role.Actions
                AssignableScopes = @($role.AssignableScopes)
            }
        }
        Write-Info "    RoleDefinitions: $($resources.RoleDefinitions.Count)"
    }

    # --- Rolltilldelningar ---
    $roleAssignments = Get-AzRoleAssignment -Scope $scope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -ieq $scope }
    if ($roleAssignments) {
        foreach ($ra in $roleAssignments) {
            $resources.RoleAssignments += @{
                ResourceId          = $ra.RoleAssignmentId
                Type                = 'roleAssignment'
                RoleDefinitionId    = $ra.RoleDefinitionId
                PrincipalId         = $ra.ObjectId
                PrincipalType       = $ra.ObjectType
                Scope               = $scope
            }
        }
        Write-Info "    RoleAssignments: $($resources.RoleAssignments.Count)"
    }

    $total = $resources.PolicyDefinitions.Count +
             $resources.PolicySetDefinitions.Count +
             $resources.PolicyAssignments.Count +
             $resources.RoleDefinitions.Count +
             $resources.RoleAssignments.Count

    return @{
        Name               = $ScopeName
        Scope              = 'managementGroup'
        ManagementGroupId  = $MgId
        ResourceCount      = $total
        Resources          = $resources
    }
}

# ============================================================
# Steg 7: Samla prenumerationsnivå-policytilldelningar och
#         policyundantag för en enskild prenumeration.
#         Anropas för ALLA prenumerationer i SubscriptionPlacement,
#         inte bara plattformsprenumerationer — landing zone-prenumerationer
#         är där Deny-effect-policyer oftast påverkar workloads.
# ============================================================
function Get-SubscriptionGovernance ([string]$SubscriptionId, [string]$DisplayName) {
    Write-Info "  Skannar prenumerationsstyrning: $DisplayName ($SubscriptionId)"

    $scope = "/subscriptions/$SubscriptionId"

    $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if (-not $ctx) {
        $msg = "Kunde inte sätta kontext för prenumeration $SubscriptionId — hoppar över prenumerationsstyrning."
        $Script:Warnings += $msg
        Write-Warn $msg
        return $null
    }

    $assignments = @(Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue)
    $subAssignments = @()
    foreach ($a in $assignments) {
        $aScope = Get-PropSafe $a 'Scope'
        if (-not $aScope) {
            $props = Get-PropSafe $a 'Properties'
            if ($props) { $aScope = $props.scope }
        }
        if ($aScope -and ($aScope -ine $scope)) { continue }

        $params = $null
        try {
            $rawParams = Get-PropSafe $a 'Parameter', 'Parameters'
            $params = if ($rawParams -is [string]) { $rawParams | ConvertFrom-Json }
                      else { $rawParams | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
        }
        catch { }

        $identity = $null
        $aIdentity = Get-PropSafe $a 'Identity'
        if ($aIdentity) {
            $identity = @{
                Type        = (Get-PropSafe $aIdentity 'Type')
                PrincipalId = (Get-PropSafe $aIdentity 'PrincipalId')
            }
        }

        $rid = Get-PropSafe $a 'ResourceId', 'PolicyAssignmentId', 'Id'
        $subAssignments += @{
            ResourceId         = $rid
            Type               = 'policyAssignment'
            DisplayName        = (Get-PropSafe $a 'DisplayName')
            PolicyDefinitionId = (Get-PropSafe $a 'PolicyDefinitionId')
            Parameters         = $params
            EnforcementMode    = (Get-PropSafe $a 'EnforcementMode')
            Identity           = $identity
            Scope              = $scope
        }
    }
    if ($subAssignments.Count -gt 0) { Write-Info "    PolicyAssignments: $($subAssignments.Count)" }

    # --- Policyundantag (inget rent Az-cmdlet — använd REST) ---
    $subExemptions = @()
    $exemptionResponse = Invoke-AzRestMethod `
        -Path "$scope/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview" `
        -Method GET `
        -ErrorAction SilentlyContinue
    if ($exemptionResponse -and $exemptionResponse.StatusCode -eq 200) {
        $exemptionData = $exemptionResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($exemptionData -and $exemptionData.PSObject.Properties['value']) {
            foreach ($ex in @($exemptionData.value)) {
                $props = if ($ex.PSObject.Properties['properties']) { $ex.properties } else { $ex }
                $subExemptions += @{
                    ResourceId                   = $ex.id
                    Name                         = $ex.name
                    DisplayName                  = (Get-PropSafe $props 'displayName', 'DisplayName')
                    ExemptionCategory            = (Get-PropSafe $props 'exemptionCategory', 'ExemptionCategory')
                    PolicyAssignmentId           = (Get-PropSafe $props 'policyAssignmentId', 'PolicyAssignmentId')
                    PolicyDefinitionReferenceIds = @(if ($props.PSObject.Properties['policyDefinitionReferenceIds']) { $props.policyDefinitionReferenceIds } else { @() })
                    Scope                        = $scope
                }
            }
        }
    }
    if ($subExemptions.Count -gt 0) { Write-Info "    PolicyExemptions: $($subExemptions.Count)" }

    return @{
        SubscriptionId    = $SubscriptionId
        DisplayName       = $DisplayName
        PolicyAssignments = $subAssignments
        PolicyExemptions  = $subExemptions
    }
}

# ============================================================
# Steg 8: Samla infrastrukturresurser för en prenumeration
# ============================================================
function Get-InfrastructureScope ([string]$SubscriptionId, [string]$ScopeName) {
    Write-Info "  Skannar infrastruktur-scope: $ScopeName (sub: $SubscriptionId)"

    $resources = @{
        ResourceGroups = @()
        KeyResources   = @()
    }

    $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if (-not $ctx) {
        $msg = "Kunde inte sätta kontext för prenumeration $SubscriptionId — hoppar över infrastruktur-scope."
        $Script:Warnings += $msg
        Write-Warn $msg
        return $null
    }

    # --- Resursgrupper ---
    $rgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue)
    if ($rgs) {
        foreach ($rg in $rgs) {
            $resources.ResourceGroups += @{
                Name     = $rg.ResourceGroupName
                Location = $rg.Location
                Tags     = $rg.Tags
            }
        }
        Write-Info "    Resursgrupper: $($resources.ResourceGroups.Count)"
    }

    # --- Resurslås ---
    $locks = @()

    # Prenumerationsnivå-lås (inget ResourceGroupName = scope på prenumerationsnivå)
    $subLocks = @(Get-AzResourceLock -ErrorAction SilentlyContinue |
        Where-Object { -not $_.ResourceGroupName })
    foreach ($lock in $subLocks) {
        $locks += @{
            Name       = $lock.Name
            Level      = $lock.Properties.level
            Scope      = 'subscription'
            Notes      = $lock.Properties.notes
            ResourceId = $lock.LockId
        }
    }

    # Per-resursgrupp-lås (täcker RG-nivå och resursnivå-lås)
    foreach ($rg in $rgs) {
        $rgLocks = @(Get-AzResourceLock -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue)
        foreach ($lock in $rgLocks) {
            $targetScope = if ($lock.ResourceName -and $lock.ResourceType -ne 'Microsoft.Authorization/locks') {
                'resource'
            } elseif ($lock.ResourceGroupName) {
                'resourceGroup'
            } else { 'subscription' }

            $locks += @{
                Name          = $lock.Name
                Level         = $lock.Properties.level
                Scope         = $targetScope
                ResourceGroup = $lock.ResourceGroupName
                ResourceName  = $lock.ResourceName
                ResourceType  = $lock.ResourceType
                Notes         = $lock.Properties.notes
                ResourceId    = $lock.LockId
            }
        }
    }

    $resources['ResourceLocks'] = $locks
    Write-Info "    Resurslås: $($locks.Count)"

    # --- Log Analytics-arbetsytor ---
    $laws = @(Get-AzResource -ResourceType 'Microsoft.OperationalInsights/workspaces' -ErrorAction SilentlyContinue)
    if ($laws) {
        foreach ($law in $laws) {
            $detail = Get-AzOperationalInsightsWorkspace `
                -ResourceGroupName $law.ResourceGroupName `
                -Name $law.Name `
                -ErrorAction SilentlyContinue
            $resources.KeyResources += @{
                ResourceId    = $law.ResourceId
                Type          = 'logAnalyticsWorkspace'
                Name          = $law.Name
                Location      = $law.Location
                ResourceGroup = $law.ResourceGroupName
                Sku           = if ($detail) { $detail.Sku } else { $null }
                RetentionDays = if ($detail) { $detail.RetentionInDays } else { $null }
                Tags          = $law.Tags
            }
        }
        Write-Info "    Log Analytics-arbetsytor: $($laws.Count)"
    }

    # --- Automation-konton ---
    $aas = @(Get-AzResource -ResourceType 'Microsoft.Automation/automationAccounts' -ErrorAction SilentlyContinue)
    if ($aas) {
        foreach ($aa in $aas) {
            $resources.KeyResources += @{
                ResourceId    = $aa.ResourceId
                Type          = 'automationAccount'
                Name          = $aa.Name
                Location      = $aa.Location
                ResourceGroup = $aa.ResourceGroupName
                Tags          = $aa.Tags
            }
        }
        Write-Info "    Automation-konton: $($aas.Count)"
    }

    # --- Hubb-VNet:ar (VNet med GatewaySubnet eller AzureFirewallSubnet indikerar hubb) ---
    $vnets = @(Get-AzVirtualNetwork -ErrorAction SilentlyContinue)
    if ($vnets) {
        foreach ($vnet in $vnets) {
            $subnetNames = @($vnet.Subnets | ForEach-Object { $_.Name })
            $isHub       = ($subnetNames -contains 'GatewaySubnet') -or
                           ($subnetNames -contains 'AzureFirewallSubnet') -or
                           ($subnetNames -contains 'AzureFirewallManagementSubnet')

            $peerings = @($vnet.VirtualNetworkPeerings | ForEach-Object {
                @{
                    Name                          = $_.Name
                    RemoteVirtualNetworkId        = $_.RemoteVirtualNetwork.Id
                    PeeringState                  = $_.PeeringState
                    AllowGatewayTransit           = $_.AllowGatewayTransit
                    UseRemoteGateways             = $_.UseRemoteGateways
                    AllowForwardedTraffic         = $_.AllowForwardedTraffic
                }
            })

            $subnets = @($vnet.Subnets | ForEach-Object {
                @{
                    Name          = $_.Name
                    AddressPrefix = $_.AddressPrefix
                    NsgId         = if ($_.NetworkSecurityGroup) { $_.NetworkSecurityGroup.Id } else { $null }
                    RouteTableId  = if ($_.RouteTable) { $_.RouteTable.Id } else { $null }
                }
            })

            $resources.KeyResources += @{
                ResourceId     = $vnet.Id
                Type           = if ($isHub) { 'hubVirtualNetwork' } else { 'virtualNetwork' }
                Name           = $vnet.Name
                Location       = $vnet.Location
                ResourceGroup  = $vnet.ResourceGroupName
                AddressSpace   = @($vnet.AddressSpace.AddressPrefixes)
                Subnets        = $subnets
                Peerings       = $peerings
                Tags           = $vnet.Tag
            }
        }
        Write-Info "    Virtuella nätverk: $($vnets.Count)"
    }

    # --- Azure Firewalls ---
    $firewalls = @(Get-AzFirewall -ErrorAction SilentlyContinue)
    if ($firewalls) {
        foreach ($fw in $firewalls) {
            $resources.KeyResources += @{
                ResourceId      = $fw.Id
                Type            = 'azureFirewall'
                Name            = $fw.Name
                Location        = $fw.Location
                ResourceGroup   = $fw.ResourceGroupName
                Sku             = $fw.Sku
                ThreatIntelMode = $fw.ThreatIntelMode
                Tags            = $fw.Tag
            }
        }
        Write-Info "    Azure Firewalls: $($firewalls.Count)"
    }

    # --- Publika IP-adresser ---
    $pips = @(Get-AzPublicIpAddress -ErrorAction SilentlyContinue)
    if ($pips) {
        foreach ($pip in $pips) {
            $resources.KeyResources += @{
                ResourceId       = $pip.Id
                Type             = 'publicIpAddress'
                Name             = $pip.Name
                Location         = $pip.Location
                ResourceGroup    = $pip.ResourceGroupName
                AllocationMethod = $pip.PublicIpAllocationMethod
                Sku              = $pip.Sku.Name
                Tags             = $pip.Tag
            }
        }
        Write-Info "    Publika IP-adresser: $($pips.Count)"
    }

    # --- NSG:er ---
    $nsgs = @(Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue)
    if ($nsgs) {
        foreach ($nsg in $nsgs) {
            $resources.KeyResources += @{
                ResourceId    = $nsg.Id
                Type          = 'networkSecurityGroup'
                Name          = $nsg.Name
                Location      = $nsg.Location
                ResourceGroup = $nsg.ResourceGroupName
                RuleCount     = $nsg.SecurityRules.Count
                Tags          = $nsg.Tag
            }
        }
        Write-Info "    NSG:er: $($nsgs.Count)"
    }

    # --- Routningstabeller ---
    $rts = @(Get-AzRouteTable -ErrorAction SilentlyContinue)
    if ($rts) {
        foreach ($rt in $rts) {
            $resources.KeyResources += @{
                ResourceId                 = $rt.Id
                Type                       = 'routeTable'
                Name                       = $rt.Name
                Location                   = $rt.Location
                ResourceGroup              = $rt.ResourceGroupName
                RouteCount                 = $rt.Routes.Count
                DisableBgpRoutePropagation = $rt.DisableBgpRoutePropagation
                Tags                       = $rt.Tag
            }
        }
        Write-Info "    Routningstabeller: $($rts.Count)"
    }

    # --- Privata DNS-zoner ---
    $dnsZones = @(Get-AzPrivateDnsZone -ErrorAction SilentlyContinue)
    if ($dnsZones) {
        foreach ($zone in $dnsZones) {
            $links = @(Get-AzPrivateDnsVirtualNetworkLink `
                -ResourceGroupName $zone.ResourceGroupName `
                -ZoneName $zone.Name `
                -ErrorAction SilentlyContinue)

            $vnetLinks = @($links | ForEach-Object {
                @{
                    Name                = $_.Name
                    VirtualNetworkId    = $_.VirtualNetworkId
                    RegistrationEnabled = $_.RegistrationEnabled
                    ProvisioningState   = $_.ProvisioningState
                }
            })

            $resources.KeyResources += @{
                ResourceId     = $zone.ResourceId
                Type           = 'privateDnsZone'
                Name           = $zone.Name
                ResourceGroup  = $zone.ResourceGroupName
                Tags           = $zone.Tags
                VNetLinks      = $vnetLinks
                RecordSetCount = $zone.NumberOfRecordSets
            }
        }
        Write-Info "    Privata DNS-zoner: $($dnsZones.Count)"
    }

    # --- DDoS-skyddsplaner ---
    $ddosPlans = @(Get-AzDdosProtectionPlan -ErrorAction SilentlyContinue)
    if ($ddosPlans) {
        foreach ($ddos in $ddosPlans) {
            $resources.KeyResources += @{
                ResourceId    = $ddos.Id
                Type          = 'ddosProtectionPlan'
                Name          = $ddos.Name
                Location      = $ddos.Location
                ResourceGroup = $ddos.ResourceGroupName
                Tags          = $ddos.Tag
            }
        }
        Write-Info "    DDoS-skyddsplaner: $($ddosPlans.Count)"
    }

    # --- Bastion Hosts ---
    $bastionRes = @(Get-AzResource -ResourceType 'Microsoft.Network/bastionHosts' -ErrorAction SilentlyContinue)
    if ($bastionRes) {
        foreach ($b in $bastionRes) {
            $bDetail = Get-AzBastion -ResourceGroupName $b.ResourceGroupName -Name $b.Name -ErrorAction SilentlyContinue
            $resources.KeyResources += @{
                ResourceId    = $b.ResourceId
                Type          = 'bastionHost'
                Name          = $b.Name
                Location      = $b.Location
                ResourceGroup = $b.ResourceGroupName
                Sku           = if ($bDetail -and $bDetail.Sku) { $bDetail.Sku.Name } else { $null }
                ScaleUnits    = if ($bDetail) { $bDetail.ScaleUnit } else { $null }
                Tags          = $b.Tags
            }
        }
        Write-Info "    Bastion Hosts: $($bastionRes.Count)"
    }

    # --- VPN- och ExpressRoute-gateways ---
    $gwRes = @(Get-AzResource -ResourceType 'Microsoft.Network/virtualNetworkGateways' -ErrorAction SilentlyContinue)
    $vpnGwCount = 0; $erGwCount = 0
    foreach ($gw in $gwRes) {
        $gwDetail = Get-AzVirtualNetworkGateway -ResourceGroupName $gw.ResourceGroupName -Name $gw.Name -ErrorAction SilentlyContinue
        if (-not $gwDetail) { continue }
        $gwType = [string]$gwDetail.GatewayType
        $resources.KeyResources += @{
            ResourceId    = $gw.ResourceId
            Type          = if ($gwType -eq 'ExpressRoute') { 'expressRouteGateway' } else { 'vpnGateway' }
            Name          = $gw.Name
            Location      = $gw.Location
            ResourceGroup = $gw.ResourceGroupName
            GatewayType   = $gwType
            VpnType       = [string]$gwDetail.VpnType
            Sku           = if ($gwDetail.Sku) { $gwDetail.Sku.Name } else { $null }
            Tags          = $gw.Tags
        }
        if ($gwType -eq 'ExpressRoute') { $erGwCount++ } else { $vpnGwCount++ }
    }
    if ($vpnGwCount -gt 0) { Write-Info "    VPN-gateways: $vpnGwCount" }
    if ($erGwCount -gt 0)  { Write-Info "    ExpressRoute-gateways: $erGwCount" }

    # --- Brandväggspolicyer ---
    $fwPolicyRes = @(Get-AzResource -ResourceType 'Microsoft.Network/firewallPolicies' -ErrorAction SilentlyContinue)
    if ($fwPolicyRes) {
        foreach ($fp in $fwPolicyRes) {
            $fpDetail = Get-AzFirewallPolicy -ResourceGroupName $fp.ResourceGroupName -Name $fp.Name -ErrorAction SilentlyContinue
            $resources.KeyResources += @{
                ResourceId      = $fp.ResourceId
                Type            = 'firewallPolicy'
                Name            = $fp.Name
                Location        = $fp.Location
                ResourceGroup   = $fp.ResourceGroupName
                SkuTier         = if ($fpDetail -and $fpDetail.Sku) { $fpDetail.Sku.Tier } else { $null }
                ThreatIntelMode = if ($fpDetail) { $fpDetail.ThreatIntelMode } else { $null }
                Tags            = $fp.Tags
            }
        }
        Write-Info "    Brandväggspolicyer: $($fwPolicyRes.Count)"
    }

    # --- DNS Private Resolvers ---
    $resolverRes = @(Get-AzResource -ResourceType 'Microsoft.Network/dnsResolvers' -ErrorAction SilentlyContinue)
    if ($resolverRes) {
        foreach ($r in $resolverRes) {
            $resources.KeyResources += @{
                ResourceId    = $r.ResourceId
                Type          = 'dnsPrivateResolver'
                Name          = $r.Name
                Location      = $r.Location
                ResourceGroup = $r.ResourceGroupName
                Tags          = $r.Tags
            }
        }
        Write-Info "    DNS Private Resolvers: $($resolverRes.Count)"
    }

    # --- Datainsamlingsregler ---
    $dcrRes = @(Get-AzResource -ResourceType 'Microsoft.Insights/dataCollectionRules' -ErrorAction SilentlyContinue)
    if ($dcrRes) {
        foreach ($dcr in $dcrRes) {
            $resources.KeyResources += @{
                ResourceId    = $dcr.ResourceId
                Type          = 'dataCollectionRule'
                Name          = $dcr.Name
                Location      = $dcr.Location
                ResourceGroup = $dcr.ResourceGroupName
                Tags          = $dcr.Tags
            }
        }
        Write-Info "    Datainsamlingsregler: $($dcrRes.Count)"
    }

    # --- Användartilldelade managed identities ---
    $uamiRes = @(Get-AzResource -ResourceType 'Microsoft.ManagedIdentity/userAssignedIdentities' -ErrorAction SilentlyContinue)
    if ($uamiRes) {
        foreach ($u in $uamiRes) {
            $resources.KeyResources += @{
                ResourceId    = $u.ResourceId
                Type          = 'userAssignedIdentity'
                Name          = $u.Name
                Location      = $u.Location
                ResourceGroup = $u.ResourceGroupName
                Tags          = $u.Tags
            }
        }
        Write-Info "    Användartilldelade managed identities: $($uamiRes.Count)"
    }

    $total = $resources.ResourceGroups.Count + $resources.KeyResources.Count

    return @{
        Name           = $ScopeName
        Scope          = 'subscription'
        SubscriptionId = $SubscriptionId
        ResourceCount  = $total
        Resources      = $resources
    }
}

# ============================================================
# Steg 8: Mappa MG-hierarkin till namngivna governance-scopes
#
# Speglar scope-namnen i Export-ALZStackState.ps1 så att
# Compare-ALZStackState.ps1 kan matcha dem efter namn.
# ============================================================
function Get-GovernanceScopesFromHierarchy ([hashtable]$Root) {
    $scopes = @()

    $allMgIds = Get-AllMgIds -HierarchyNode $Root

    $intRootScope = Get-GovernanceScope -MgId $Root.Name -ScopeName 'governance-int-root'
    if ($intRootScope) { $scopes += $intRootScope }

    $namedScopes = @{
        'platform'       = 'governance-platform'
        'connectivity'   = 'governance-platform-connectivity'
        'identity'       = 'governance-platform-identity'
        'management'     = 'governance-platform-management'
        'security'       = 'governance-platform-security'
        'landingzones'   = 'governance-landingzones'
        'corp'           = 'governance-landingzones-corp'
        'online'         = 'governance-landingzones-online'
        'sandbox'        = 'governance-sandbox'
        'decommissioned' = 'governance-decommissioned'
    }

    foreach ($mgId in ($allMgIds | Where-Object { $_ -ne $Root.Name })) {
        $normalizedMgId = Get-NormalizedMgName $mgId
        $scopeName = if ($namedScopes.ContainsKey($normalizedMgId)) {
            $namedScopes[$normalizedMgId]
        }
        else {
            "governance-mg-$mgId"
        }

        $scopeData = Get-GovernanceScope -MgId $mgId -ScopeName $scopeName
        if ($scopeData) { $scopes += $scopeData }
    }

    return $scopes
}

# ============================================================
# Huvudprogram
# ============================================================

Write-Host ''
if ($NoColor) { Write-Host 'Export-BrownfieldState' } else { Write-Host "`e[1mExport-BrownfieldState`e[0m" }
Write-Host '(skrivskyddat — inga ändringar görs i tenanten)'
Write-Host ''

$Script:TenantId                 = $TenantId
$Script:RootManagementGroupId    = $RootManagementGroupId
$Script:PlatformSubscriptionIds  = $PlatformSubscriptionIds
$Script:Warnings                 = @()
$Script:ActualMgIds              = @()
$Script:SubscriptionPlacement    = @{}

Resolve-TenantId
Resolve-RootManagementGroup

# ============================================================
# Bygg MG-hierarki
# ============================================================
$mgHierarchy = $null

if ($Script:RootManagementGroupId -ne '') {
    Write-Step 'Bygger management group-hierarki'
    $mgHierarchy = Get-MgHierarchy -GroupId $Script:RootManagementGroupId

    if ($mgHierarchy) {
        $allIds = Get-AllMgIds -HierarchyNode $mgHierarchy
        $Script:ActualMgIds = $allIds
        Write-Ok "MG-hierarki byggd — $($allIds.Count) management group(s)"

        # Samla prenumerationsplacering per MG för blast-radius-analys i Compare
        Write-Step 'Samlar prenumerationsplacering'
        foreach ($mgId in $allIds) {
            $response = Invoke-AzRestMethod `
                -Path "/providers/Microsoft.Management/managementGroups/$mgId/subscriptions?api-version=2020-05-01" `
                -Method GET -ErrorAction SilentlyContinue
            if ($response -and $response.StatusCode -eq 200) {
                $subs = ($response.Content | ConvertFrom-Json).value
                if ($subs) {
                    $Script:SubscriptionPlacement[$mgId] = @($subs | ForEach-Object {
                        @{ Id = $_.name; DisplayName = $_.properties.displayName }
                    })
                }
            }
        }
        $placedCount = ($Script:SubscriptionPlacement.Values | ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum
        Write-Ok "Prenumerationsplacering insamlad — $placedCount prenumeration(er) i $($Script:SubscriptionPlacement.Count) MG(s)"
    }
    else {
        $msg = "Kunde inte expandera MG-hierarkin från rot '$Script:RootManagementGroupId'."
        $Script:Warnings += $msg
        Write-Warn $msg
    }
}

# ============================================================
# Governance-scopes
# ============================================================
$governanceScopes = @()

if ($mgHierarchy) {
    Write-Step 'Söker efter governance-resurser'
    try {
        $governanceScopes = Get-GovernanceScopesFromHierarchy -Root $mgHierarchy
        Write-Ok "Governance-scopes insamlade: $($governanceScopes.Count)"

        # Markera policydriven rolltilldelningar för att hjälpa Compare identifiera orphan-risk
        $allMiPrincipalIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($gs in $governanceScopes) {
            foreach ($pa in @($gs.Resources.PolicyAssignments)) {
                $mid = $pa['ManagedIdentityPrincipalId']
                if ($mid) { [void]$allMiPrincipalIds.Add($mid) }
            }
        }
        foreach ($gs in $governanceScopes) {
            foreach ($ra in @($gs.Resources.RoleAssignments)) {
                $raPrincipalId = $ra['PrincipalId']
                $ra['IsPolicyDriven'] = ($null -ne $raPrincipalId -and $allMiPrincipalIds.Contains($raPrincipalId))
            }
        }
        $totalPolicyDrivenRas = ($governanceScopes |
            ForEach-Object { @($_.Resources.RoleAssignments) | Where-Object { $_['IsPolicyDriven'] } } |
            Measure-Object).Count
        if ($totalPolicyDrivenRas -gt 0) { Write-Info "  Policydrivna rolltilldelningar identifierade: $totalPolicyDrivenRas" }
    }
    catch {
        $msg = "Governance-discovery misslyckades: $($_.Exception.Message)"
        $Script:Warnings += $msg
        Write-Warn $msg
    }
}
else {
    Write-Warn 'Hoppar över governance-discovery — ingen MG-hierarki tillgänglig.'
}

# ============================================================
# Lös plattformsprenumerationer, skanna sedan infrastruktur
# ============================================================
Resolve-PlatformSubscriptions

$infrastructureScopes = @()

if ($Script:PlatformSubscriptionIds.Count -gt 0) {
    Write-Step 'Söker efter infrastrukturresurser'

    $normalizedToActualInfra = @{}
    if ($Script:ActualMgIds) {
        foreach ($actualId in $Script:ActualMgIds) {
            $normalizedToActualInfra[(Get-NormalizedMgName $actualId)] = $actualId
        }
    }

    foreach ($subId in $Script:PlatformSubscriptionIds) {
        $scopeName = "core-subscription-$subId"
        foreach ($mgName in $AlzPlatformMgs) {
            $actualMgId = if ($normalizedToActualInfra.ContainsKey($mgName)) {
                $normalizedToActualInfra[$mgName]
            } else {
                $mgName
            }

            $response = Invoke-AzRestMethod `
                -Path "/providers/Microsoft.Management/managementGroups/$actualMgId/subscriptions?api-version=2020-05-01" `
                -Method GET `
                -ErrorAction SilentlyContinue

            if ($response -and $response.StatusCode -eq 200) {
                $match = ($response.Content | ConvertFrom-Json).value |
                    Where-Object { $_.name -eq $subId }
                if ($match) {
                    $scopeName = "core-$mgName"
                    break
                }
            }
        }

        # Byt namn på management-scope för att matcha Export-ALZStackState-namngivning
        if ($scopeName -eq 'core-management') { $scopeName = 'core-logging' }

        try {
            $infraScope = Get-InfrastructureScope -SubscriptionId $subId -ScopeName $scopeName
            if ($infraScope) {
                $infrastructureScopes += $infraScope
                Write-Ok "  $scopeName — $($infraScope.ResourceCount) resurs(er)"
            }
        }
        catch {
            $msg = "Infrastruktur-discovery misslyckades för prenumeration $subId`: $($_.Exception.Message)"
            $Script:Warnings += $msg
            Write-Fail $msg
        }
    }
}

# ============================================================
# Prenumerationsstyrning (tilldelningar + undantag)
# Skannar ALLA prenumerationer i SubscriptionPlacement — inte bara
# plattformsprenumerationer — eftersom landing zone-prenumerationer
# är där Deny-effect-policyer oftast påverkar workloads.
# ============================================================
$subscriptionGovernanceScopes = @()

if ($Script:SubscriptionPlacement.Count -gt 0) {
    Write-Step 'Skannar prenumerationsnivå-styrning'

    $allSubsSeen = [System.Collections.Generic.HashSet[string]]::new()
    $allSubsList = [System.Collections.Generic.List[object]]::new()
    foreach ($mgSubs in $Script:SubscriptionPlacement.Values) {
        foreach ($sub in @($mgSubs)) {
            $subId = if ($sub -is [hashtable] -and $sub.ContainsKey('Id')) { $sub['Id'] }
                     elseif ($sub.PSObject.Properties['Id']) { $sub.Id }
                     elseif ($sub -is [string]) { $sub }
                     else { $null }
            if ($subId -and $allSubsSeen.Add($subId)) {
                $displayName = if ($sub -is [hashtable] -and $sub.ContainsKey('DisplayName') -and $sub['DisplayName']) { $sub['DisplayName'] }
                               elseif ($sub.PSObject.Properties['DisplayName'] -and $sub.DisplayName) { $sub.DisplayName }
                               else { $subId }
                [void]$allSubsList.Add(@{ Id = $subId; DisplayName = $displayName })
            }
        }
    }

    Write-Info "  $($allSubsList.Count) prenumeration(er) att skanna"

    foreach ($sub in $allSubsList) {
        try {
            $subGov = Get-SubscriptionGovernance -SubscriptionId $sub.Id -DisplayName $sub.DisplayName
            if ($subGov) {
                $subscriptionGovernanceScopes += $subGov
            }
        }
        catch {
            $msg = "Prenumerationsstyrningsskanning misslyckades för $($sub.Id): $($_.Exception.Message)"
            $Script:Warnings += $msg
            Write-Warn $msg
        }
    }

    $totalSubAssignments = ($subscriptionGovernanceScopes | ForEach-Object { $_.PolicyAssignments.Count } | Measure-Object -Sum).Sum
    $totalSubExemptions  = ($subscriptionGovernanceScopes | ForEach-Object { $_.PolicyExemptions.Count }  | Measure-Object -Sum).Sum
    Write-Ok "Prenumerationsstyrning insamlad — $totalSubAssignments tilldelning(ar), $totalSubExemptions undantag i $($subscriptionGovernanceScopes.Count) prenumeration(er)"
}
else {
    Write-Info 'Inga prenumerationsplaceringsdata — hoppar över prenumerationsnivå-styrningsskanning.'
    Write-Info '  (Kör om efter att MG-hierarkin är byggd och prenumerationer är placerade under den)'
}

# ============================================================
# Defender for Cloud-state (per-prenumeration REST-skanning)
# ============================================================
function Get-DefenderState ([string]$SubscriptionId) {
    $plans = @()
    $r = Invoke-AzRestMethod `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Security/pricings?api-version=2024-01-01" `
        -Method GET -ErrorAction SilentlyContinue
    if ($r -and $r.StatusCode -eq 200) {
        $data = $r.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties['value']) {
            foreach ($p in @($data.value)) {
                $plans += @{
                    Name        = $p.name
                    PricingTier = if ($p.properties.PSObject.Properties['pricingTier'])  { $p.properties.pricingTier }  else { $null }
                    SubPlan     = if ($p.properties.PSObject.Properties['subPlan'])      { $p.properties.subPlan }      else { $null }
                }
            }
        }
    }

    $contacts = @()
    $r2 = Invoke-AzRestMethod `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Security/securityContacts?api-version=2020-01-01-preview" `
        -Method GET -ErrorAction SilentlyContinue
    if ($r2 -and $r2.StatusCode -eq 200) {
        $data2 = $r2.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data2 -and $data2.PSObject.Properties['value']) {
            foreach ($c in @($data2.value)) {
                $props = $c.properties
                $contacts += @{
                    Name          = $c.name
                    Emails        = if ($props.PSObject.Properties['emails'])              { $props.emails }              else { $null }
                    Phone         = if ($props.PSObject.Properties['phone'])               { $props.phone }               else { $null }
                    Notifications = if ($props.PSObject.Properties['notificationsByRole']) { $props.notificationsByRole } else { $null }
                }
            }
        }
    }

    $autoProv = @()
    $r3 = Invoke-AzRestMethod `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Security/autoProvisioningSettings?api-version=2017-08-01-preview" `
        -Method GET -ErrorAction SilentlyContinue
    if ($r3 -and $r3.StatusCode -eq 200) {
        $data3 = $r3.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data3 -and $data3.PSObject.Properties['value']) {
            foreach ($s in @($data3.value)) {
                $autoProv += @{
                    Name          = $s.name
                    AutoProvision = if ($s.properties.PSObject.Properties['autoProvision']) { $s.properties.autoProvision } else { $null }
                }
            }
        }
    }

    return @{
        SubscriptionId   = $SubscriptionId
        DefenderPlans    = $plans
        SecurityContacts = $contacts
        AutoProvisioning = $autoProv
    }
}

# ============================================================
# Blueprint-tilldelningar (per-prenumeration REST-skanning)
# ============================================================
function Get-BlueprintAssignments ([string]$SubscriptionId) {
    $response = Invoke-AzRestMethod `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Blueprint/blueprintAssignments?api-version=2018-11-01-preview" `
        -Method GET -ErrorAction SilentlyContinue
    if ($response -and $response.StatusCode -eq 200) {
        $data = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties['value']) {
            return @($data.value | ForEach-Object {
                $props = $_.properties
                @{
                    Name              = $_.name
                    BlueprintId       = if ($props.PSObject.Properties['blueprintId'])       { $props.blueprintId }       else { $null }
                    Scope             = "/subscriptions/$SubscriptionId"
                    SubscriptionId    = $SubscriptionId
                    ProvisioningState = if ($props.PSObject.Properties['provisioningState'])  { $props.provisioningState } else { $null }
                    LockMode          = if ($props.PSObject.Properties['locks'] -and $props.locks) { $props.locks.mode } else { 'None' }
                    Parameters        = if ($props.PSObject.Properties['parameters'])         { $props.parameters }        else { $null }
                    ResourceGroups    = if ($props.PSObject.Properties['resourceGroups'])     { $props.resourceGroups }    else { $null }
                }
            })
        }
    }
    return @()
}

$defenderStateList = @()

if ($Script:PlatformSubscriptionIds.Count -gt 0) {
    Write-Step 'Skannar Defender for Cloud-state'
    foreach ($subId in $Script:PlatformSubscriptionIds) {
        try {
            $ctx = Set-AzContext -SubscriptionId $subId -ErrorAction SilentlyContinue
            if (-not $ctx) { continue }
            $ds = Get-DefenderState -SubscriptionId $subId
            $defenderStateList += $ds
            $enabledPlans = @($ds.DefenderPlans | Where-Object { $_['PricingTier'] -eq 'Standard' })
            Write-Info "  $subId — $($enabledPlans.Count)/$($ds.DefenderPlans.Count) Defender-planer aktiverade"
        }
        catch {
            Write-Warn "  Defender-state-skanning misslyckades för $subId`: $($_.Exception.Message)"
        }
    }
}

$blueprintAssignments = @()

if ($Script:SubscriptionPlacement.Count -gt 0) {
    Write-Step 'Skannar blueprint-tilldelningar'

    $allSubsSeen2 = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($mgSubs in $Script:SubscriptionPlacement.Values) {
        foreach ($sub in @($mgSubs)) {
            $subId = if ($sub -is [hashtable] -and $sub.ContainsKey('Id')) { $sub['Id'] }
                     elseif ($sub.PSObject.Properties['Id']) { $sub.Id }
                     elseif ($sub -is [string]) { $sub }
                     else { $null }
            if (-not $subId -or -not $allSubsSeen2.Add($subId)) { continue }

            $found = @(Get-BlueprintAssignments -SubscriptionId $subId)
            if ($found.Count -gt 0) {
                $blueprintAssignments += $found
                Write-Warn "  $subId — $($found.Count) blueprint-tilldelning(ar) hittade"
            }
        }
    }

    if ($blueprintAssignments.Count -eq 0) {
        Write-Ok 'Inga blueprint-tilldelningar hittades'
    } else {
        Write-Warn "$($blueprintAssignments.Count) blueprint-tilldelning(ar) totalt detekterade"
    }
} else {
    Write-Info 'Inga prenumerationsplaceringsdata — hoppar över blueprint-tilldelningsskanning.'
}

# ============================================================
# Höga behörigheter — identitetsskanning vid int-root MG
# ============================================================
function Get-HighPrivilegeIdentities ([string]$MgId) {
    $response = Invoke-AzRestMethod `
        -Path "/providers/Microsoft.Management/managementGroups/$MgId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" `
        -Method GET -ErrorAction SilentlyContinue

    $highPriv = @()
    if (-not ($response -and $response.StatusCode -eq 200)) { return $highPriv }

    $body = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $body -or -not $body.PSObject.Properties['value']) { return $highPriv }

    $ownerRoleId       = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    $contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

    foreach ($ra in @($body.value)) {
        $roleDefId = ($ra.properties.roleDefinitionId -split '/')[-1]
        if ($roleDefId -eq $ownerRoleId -or $roleDefId -eq $contributorRoleId) {
            $highPriv += @{
                PrincipalId   = $ra.properties.principalId
                PrincipalType = $ra.properties.principalType
                RoleDefId     = $roleDefId
                RoleName      = if ($roleDefId -eq $ownerRoleId) { 'Owner' } else { 'Contributor' }
                Scope         = $ra.properties.scope
            }
        }
    }
    return $highPriv
}

Write-Step 'Skannar höga behörigheter vid int-root MG-scope'
$highPrivilegeIdentities = @()
if ($Script:RootManagementGroupId -ne '') {
    $highPrivilegeIdentities = @(Get-HighPrivilegeIdentities -MgId $Script:RootManagementGroupId)
    if ($highPrivilegeIdentities.Count -gt 0) {
        Write-Info "Hittade $($highPrivilegeIdentities.Count) Owner/Contributor-tilldelning(ar) vid $Script:RootManagementGroupId"
        foreach ($hp in $highPrivilegeIdentities) {
            Write-Info "  $($hp['RoleName']) — $($hp['PrincipalType']): $($hp['PrincipalId'])"
        }
    } else {
        Write-Ok 'Inga Owner/Contributor-tilldelningar hittades vid int-root MG-scope'
    }
} else {
    Write-Warn 'RootManagementGroupId ej satt — hoppar över skanning av höga behörigheter'
}

# ============================================================
# Assemblera och skriv utdata
# ============================================================
Write-Step 'Skriver utdata'

$export = @{
    ExportTimestamp          = (Get-Date -Format 'o')
    TenantId                 = $Script:TenantId
    RootManagementGroupId    = $Script:RootManagementGroupId
    DiscoveryMode            = 'in-place-takeover'
    ManagementGroupHierarchy = $mgHierarchy
    SubscriptionPlacement    = $Script:SubscriptionPlacement
    SubscriptionGovernance   = $subscriptionGovernanceScopes
    DefenderState            = $defenderStateList
    BlueprintAssignments     = $blueprintAssignments
    HighPrivilegeIdentities  = $highPrivilegeIdentities
    Scopes                   = @($governanceScopes) + @($infrastructureScopes)
    Warnings                 = $Script:Warnings
}

$export | ConvertTo-Json -Depth 30 | Out-File -FilePath $OutputFile -Encoding utf8

Write-Host ''
Write-Ok "Export klar: $OutputFile"
Write-Info "Totalt exporterade scopes:          $($export.Scopes.Count)"
Write-Info "Governance-scopes:                  $($governanceScopes.Count)"
Write-Info "Infrastruktur-scopes:               $($infrastructureScopes.Count)"
Write-Info "Prenumerationsstyrning:             $($subscriptionGovernanceScopes.Count) prenumeration(er)"
Write-Info "Defender-state-prenumerationer:     $($defenderStateList.Count)"
Write-Info "Blueprint-tilldelningar:            $($blueprintAssignments.Count)"

if ($Script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Warn "$($Script:Warnings.Count) varning(ar):"
    foreach ($w in $Script:Warnings) {
        Write-Warn "  $w"
    }
}
