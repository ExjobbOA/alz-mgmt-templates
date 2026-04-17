#Requires -Version 7
<#
.SYNOPSIS
    Genererar en platform.json-kandidat från AzGovViz-output för in-place
    takeover av en portaldriftsatt Azure Landing Zone.

.DESCRIPTION
    Läser AzGovViz-hierarkins JSON-tree + per-MG tilldelningar och härleder:
      * SUBSCRIPTION_ID_* från prenumerationsplacering under välkända MG:er
      * MG_NAME_* från hierarkin, normaliserat mot ALZ-arketyper
      * INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID + MANAGEMENT_GROUP_ID
      * LOCATION / LOCATION_PRIMARY från tilldelningsparametrar (mode)
      * SECURITY_CONTACT_EMAIL från Deploy-MDFC-Config-*-tilldelningen

    Icke-härledbara värden (PLATFORM_MODE, NETWORK_TYPE, ENABLE_TELEMETRY,
    LOCATION_SECONDARY) får defaultvärden som operatören ska granska.

    Skrivskyddat. Skriver bara till OutputDirectory.

.PARAMETER AzGovVizJsonPath
    Sökväg till JSON_<root>_<timestamp>/-mappen från AzGovVizParallel.ps1.

.PARAMETER OutputDirectory
    Där platform.json-kandidaten skrivs.

.EXAMPLE
    ./Build-PlatformJson.ps1 `
        -AzGovVizJsonPath ./azgovviz-output/JSON_alz_20260417_181200 `
        -OutputDirectory  ./takeover-fragments
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AzGovVizJsonPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Logging (matches existing scripts in this repo)
# -----------------------------------------------------------------------------
$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" } else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info ($msg) { if ($NoColor) { Write-Host "[INFO] $msg" }   else { Write-Host "`e[36m[INFO]`e[0m $msg" } }
function Write-Ok   ($msg) { if ($NoColor) { Write-Host "[OK]   $msg" }   else { Write-Host "`e[32m[OK]`e[0m   $msg" } }
function Write-Warn ($msg) { if ($NoColor) { Write-Host "[WARN] $msg" }   else { Write-Host "`e[33m[WARN]`e[0m $msg" } }

# =============================================================================
# MG-namn-normalisering — samma logik som Export-BrownfieldState
# =============================================================================
function Get-NormalizedMgName ([string]$Name) {
    if (-not $Name) { return '' }
    # Strip common ALZ prefixes (case-insensitive)
    $n = $Name -replace '^(?i)(mg-alz-|alz-|mg-)', ''
    $n = $n.ToLowerInvariant()
    # Normalize plural/variant forms
    switch -Regex ($n) {
        '^sandbox(e?s)?$' { return 'sandbox' }
        '^landing[-_]?zones?$' { return 'landingzones' }
        '^decommissioned?$' { return 'decommissioned' }
        default { return $n }
    }
}

# =============================================================================
# Azure-regionigenkänning (enkel heuristik)
# =============================================================================
$AzureRegionHints = @(
    'central', 'north', 'south', 'east', 'west', 'europe', 'asia', 'australia',
    'brazil', 'japan', 'uk', 'us', 'canada', 'france', 'germany', 'india', 'norway',
    'sweden', 'uae', 'korea', 'switzerland', 'poland', 'italy', 'spain', 'qatar',
    'israel', 'mexico', 'chile', 'newzealand', 'malaysia', 'indonesia'
)
function Test-IsAzureRegion ([string]$Value) {
    if (-not $Value) { return $false }
    if ($Value.Length -lt 5 -or $Value.Length -gt 30) { return $false }
    if ($Value -notmatch '^[a-z][a-z0-9]+$') { return $false }
    foreach ($h in $AzureRegionHints) { if ($Value -match $h) { return $true } }
    return $false
}

# =============================================================================
# AzGovViz-input-upptäckt
# =============================================================================
function Find-TenantJsonFile ([string]$JsonRoot) {
    # AzGovViz writes AzGovViz_<version>_<timestamp>_<mgId>.json at the root
    # of JSON_<root>_<timestamp>/. Filter out HierarchyMapOnly/ManagementGroupsOnly
    # variants so we get the full tree.
    $candidates = @(Get-ChildItem -Path $JsonRoot -Filter 'AzGovViz_*.json' -File |
        Where-Object { $_.Name -notmatch 'HierarchyMapOnly|ManagementGroupsOnly' } |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "No AzGovViz tenant JSON found in $JsonRoot (expected AzGovViz_*.json)"
    }
    return $candidates[0].FullName
}

# =============================================================================
# Hierarki-walk — hittar arketyp-MG:er i trädet
# =============================================================================

# Returns a flat hashtable: normalizedName -> @{ MgId; MgName; ParentId; Node }
# Populated by walking the tree top-down from int-root.
function Find-ArchetypeMgs {
    param(
        [object]$IntRootNode,
        [string]$IntRootMgId
    )
    $result = @{}

    # int-root's direct children: platform, landingzones, sandbox, decommissioned
    $rootChildrenExpected = @('platform', 'landingzones', 'sandbox', 'decommissioned')

    # platform's children: connectivity, identity, management, security
    $platformChildrenExpected = @('connectivity', 'identity', 'management', 'security')

    # landingzones' children: corp, online
    $lzChildrenExpected = @('corp', 'online')

    if (-not $IntRootNode.PSObject.Properties['ManagementGroups']) { return $result }

    foreach ($childProp in $IntRootNode.ManagementGroups.PSObject.Properties) {
        $childId = $childProp.Name
        $childNode = $childProp.Value
        $normalized = Get-NormalizedMgName $childId
        if ($rootChildrenExpected -notcontains $normalized) { continue }

        $result[$normalized] = @{
            MgId     = $childId
            MgName   = if ($childNode.PSObject.Properties['MgName']) { [string]$childNode.MgName } else { $childId }
            ParentId = $IntRootMgId
            Node     = $childNode
        }

        # Recurse into platform and landingzones specifically
        if ($normalized -eq 'platform' -and $childNode.PSObject.Properties['ManagementGroups']) {
            foreach ($sub in $childNode.ManagementGroups.PSObject.Properties) {
                $subNorm = Get-NormalizedMgName $sub.Name
                if ($platformChildrenExpected -contains $subNorm) {
                    $result[$subNorm] = @{
                        MgId     = $sub.Name
                        MgName   = if ($sub.Value.PSObject.Properties['MgName']) { [string]$sub.Value.MgName } else { $sub.Name }
                        ParentId = $childId
                        Node     = $sub.Value
                    }
                }
            }
        }
        elseif ($normalized -eq 'landingzones' -and $childNode.PSObject.Properties['ManagementGroups']) {
            foreach ($sub in $childNode.ManagementGroups.PSObject.Properties) {
                $subNorm = Get-NormalizedMgName $sub.Name
                if ($lzChildrenExpected -contains $subNorm) {
                    $result[$subNorm] = @{
                        MgId     = $sub.Name
                        MgName   = if ($sub.Value.PSObject.Properties['MgName']) { [string]$sub.Value.MgName } else { $sub.Name }
                        ParentId = $childId
                        Node     = $sub.Value
                    }
                }
            }
        }
    }
    return $result
}

# Pull first subscription ID directly under a given MG node. Returns '' if none.
function Get-FirstSubIdUnderMg ([object]$MgNode) {
    if (-not $MgNode) { return '' }
    if (-not $MgNode.PSObject.Properties['Subscriptions']) { return '' }
    $subProps = @($MgNode.Subscriptions.PSObject.Properties)
    if ($subProps.Count -eq 0) { return '' }
    return $subProps[0].Name
}

# =============================================================================
# Parameterextraktion från tilldelningar — återanvänder samma
# MG-scope-JSON-filer som Build-OverrideFragments.ps1 läser
# =============================================================================
function Read-AllAssignmentParams ([string]$JsonRoot) {
    $mgRoot = Join-Path $JsonRoot 'Assignments/PolicyAssignments/Mg'
    if (-not (Test-Path $mgRoot)) { return @() }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem -Path $mgRoot -Recurse -Filter '*.json') {
        try {
            $raw = Get-Content $f.FullName -Raw | ConvertFrom-Json
        }
        catch { continue }
        if (-not $raw.PSObject.Properties['properties']) { continue }
        $p = $raw.properties
        $params = if ($p.PSObject.Properties['parameters']) { $p.parameters } else { $null }
        $name = if ($raw.PSObject.Properties['name']) { [string]$raw.name } else { $f.BaseName }
        [void]$results.Add([PSCustomObject]@{
                Name       = $name
                Parameters = $params
            })
    }
    return @($results)
}

# Find the modal Azure region across all assignment parameter values.
function Get-ModalLocation ([object[]]$Assignments) {
    $counts = @{}
    foreach ($a in $Assignments) {
        if (-not $a.Parameters) { continue }
        foreach ($pp in $a.Parameters.PSObject.Properties) {
            $v = $pp.Value
            if (-not $v -or -not $v.PSObject.Properties['value']) { continue }
            $val = $v.value
            if ($val -is [string] -and (Test-IsAzureRegion $val)) {
                if (-not $counts.ContainsKey($val)) { $counts[$val] = 0 }
                $counts[$val] = $counts[$val] + 1
            }
        }
    }
    if ($counts.Count -eq 0) { return '' }
    return ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
}

# Pull security contact email from Deploy-MDFC-Config-* first, then
# Deploy-SvcHealth-BuiltIn actionGroupEmail as fallback.
function Get-SecurityEmail ([object[]]$Assignments) {
    foreach ($a in $Assignments) {
        if ($a.Name -notmatch '^Deploy-MDFC-Config') { continue }
        if (-not $a.Parameters) { continue }
        $p = $a.Parameters
        if ($p.PSObject.Properties['emailSecurityContact']) {
            $v = $p.emailSecurityContact
            if ($v.PSObject.Properties['value'] -and $v.value) { return [string]$v.value }
        }
    }
    foreach ($a in $Assignments) {
        if ($a.Name -ne 'Deploy-SvcHealth-BuiltIn') { continue }
        if (-not $a.Parameters) { continue }
        $p = $a.Parameters
        if ($p.PSObject.Properties['actionGroupResources']) {
            $agr = $p.actionGroupResources
            if ($agr.PSObject.Properties['value'] -and $agr.value.PSObject.Properties['actionGroupEmail']) {
                $list = @($agr.value.actionGroupEmail)
                if ($list.Count -gt 0 -and $list[0]) { return [string]$list[0] }
            }
        }
    }
    return ''
}

# =============================================================================
# Main
# =============================================================================
Write-Host ''
if ($NoColor) { Write-Host 'Build-PlatformJson' } else { Write-Host "`e[1mBuild-PlatformJson`e[0m" }
Write-Host '(skrivskyddat — skriver bara till OutputDirectory)'
Write-Host ''

if (-not (Test-Path $AzGovVizJsonPath)) {
    Write-Error "AzGovViz JSON path not found: $AzGovVizJsonPath"
    exit 1
}
if (-not (Test-Path $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

Write-Info "AzGovViz input: $AzGovVizJsonPath"
Write-Info "Output dir:     $OutputDirectory"

# -----------------------------------------------------------------------------
# Läs tenant-JSON
# -----------------------------------------------------------------------------
Write-Step 'Läser tenant-JSON'
$tenantJsonFile = Find-TenantJsonFile $AzGovVizJsonPath
Write-Info "Tree file: $(Split-Path -Leaf $tenantJsonFile)"
$tenantData = Get-Content $tenantJsonFile -Raw | ConvertFrom-Json
if (-not $tenantData.PSObject.Properties['Tenant']) {
    Write-Error "Unexpected tenant JSON shape — 'Tenant' root property missing"
    exit 1
}
$tenant = $tenantData.Tenant
$tenantId = if ($tenant.PSObject.Properties['TenantId']) { [string]$tenant.TenantId } else { '' }

# -----------------------------------------------------------------------------
# Hitta int-root MG — första noden under Tenant.ManagementGroups.
# AzGovViz startar trädet vid det -ManagementGroupId som operatören passade in.
# -----------------------------------------------------------------------------
Write-Step 'Identifierar intermediate root MG'
$mgRoot = $tenant.ManagementGroups
$rootProps = @($mgRoot.PSObject.Properties)
if ($rootProps.Count -eq 0) {
    Write-Error "No management groups found in tenant JSON"
    exit 1
}
$intRoot = $rootProps[0]
$intRootMgId = $intRoot.Name
$intRootNode = $intRoot.Value
$tenantRootMgId = if ($intRootNode.PSObject.Properties['mgParentId']) { [string]$intRootNode.mgParentId } else { '' }
# mgParentId may be a full path like /providers/.../managementGroups/<guid> — extract GUID
if ($tenantRootMgId -match '/managementGroups/([^/]+)$') { $tenantRootMgId = $Matches[1] }

Write-Info "Intermediate root: $intRootMgId"
Write-Info "Tenant root:       $tenantRootMgId"
Write-Info "Tenant ID:         $tenantId"

# -----------------------------------------------------------------------------
# Hitta arketyp-MG:er
# -----------------------------------------------------------------------------
Write-Step 'Identifierar ALZ-arketyp-MG:er'
$archetypes = Find-ArchetypeMgs -IntRootNode $intRootNode -IntRootMgId $intRootMgId
foreach ($key in @('platform', 'connectivity', 'identity', 'management', 'security', 'landingzones', 'corp', 'online', 'sandbox', 'decommissioned')) {
    if ($archetypes.ContainsKey($key)) {
        Write-Info "  $($key.PadRight(16)) → $($archetypes[$key].MgId)"
    }
    else {
        Write-Warn "  $($key.PadRight(16)) — ej hittad (MG_NAME_$($key.ToUpper()) lämnas tom)"
    }
}

# -----------------------------------------------------------------------------
# Hämta prenumerationer under plattforms-MG:er
# -----------------------------------------------------------------------------
Write-Step 'Hämtar prenumerationsplacering'
$subManagement = if ($archetypes.ContainsKey('management')) { Get-FirstSubIdUnderMg $archetypes['management'].Node }   else { '' }
$subConnectivity = if ($archetypes.ContainsKey('connectivity')) { Get-FirstSubIdUnderMg $archetypes['connectivity'].Node } else { '' }
$subIdentity = if ($archetypes.ContainsKey('identity')) { Get-FirstSubIdUnderMg $archetypes['identity'].Node }     else { '' }
$subSecurity = if ($archetypes.ContainsKey('security')) { Get-FirstSubIdUnderMg $archetypes['security'].Node }     else { '' }
$subPlatform = if ($archetypes.ContainsKey('platform')) { Get-FirstSubIdUnderMg $archetypes['platform'].Node }     else { '' }

# Simple mode detection: if no connectivity/identity/management/security MGs were
# found, the tenant is simple-mode — platform holds the sub directly and all
# SUBSCRIPTION_ID_* values collapse to the same sub.
$simpleMode = -not ($archetypes.ContainsKey('connectivity') -or
    $archetypes.ContainsKey('identity') -or
    $archetypes.ContainsKey('management') -or
    $archetypes.ContainsKey('security'))

if ($simpleMode) {
    Write-Info "  Simple mode detected — all SUBSCRIPTION_ID_* collapse to platform sub"
    if (-not $subManagement) { $subManagement = $subPlatform }
    if (-not $subConnectivity) { $subConnectivity = $subPlatform }
    if (-not $subIdentity) { $subIdentity = $subPlatform }
    if (-not $subSecurity) { $subSecurity = $subPlatform }
}
else {
    # Hybrid mode: platform MG usually has no direct sub, fall back to management
    if (-not $subPlatform) { $subPlatform = $subManagement }
    if (-not $subSecurity) { $subSecurity = $subManagement }
}

Write-Info "  management:   $subManagement"
Write-Info "  connectivity: $subConnectivity"
Write-Info "  identity:     $subIdentity"
Write-Info "  security:     $subSecurity (fallback to management om tom)"
Write-Info "  platform:     $subPlatform (fallback to management om tom)"

# -----------------------------------------------------------------------------
# Härled location och säkerhets-e-post från tilldelningsparametrar
# -----------------------------------------------------------------------------
Write-Step 'Härleder location och säkerhetskontakt från tilldelningar'
$allAssignments = Read-AllAssignmentParams $AzGovVizJsonPath
Write-Info "  Tilldelningar lästa: $($allAssignments.Count)"
$location = Get-ModalLocation  $allAssignments
$securityEmail = Get-SecurityEmail  $allAssignments
Write-Info "  LOCATION:                $(if ($location) { $location } else { '(ej härledbar — lämnas tom)' })"
Write-Info "  SECURITY_CONTACT_EMAIL:  $(if ($securityEmail) { $securityEmail } else { '(ej härledbar — lämnas tom)' })"

# -----------------------------------------------------------------------------
# Sätt ihop platform.json
#
# Nyckelordning matchar alz-mgmt-oskar/config/platform.json för läsbarhet.
# Skriver en banner i slutet som markerar vilka fält som är härledda,
# vilka som är defaults och vilka som är tomma.
# -----------------------------------------------------------------------------
Write-Step 'Skriver platform.json-kandidat'

$platform = [ordered]@{
    PLATFORM_MODE                         = if ($simpleMode) { 'simple' } else { 'full' }         # default
    SUBSCRIPTION_ID_MANAGEMENT            = $subManagement
    SUBSCRIPTION_ID_PLATFORM              = $subPlatform
    SUBSCRIPTION_ID_CONNECTIVITY          = $subConnectivity
    SUBSCRIPTION_ID_IDENTITY              = $subIdentity
    SUBSCRIPTION_ID_SECURITY              = $subSecurity
    INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID = $intRootMgId
    MG_NAME_PLATFORM                      = if ($archetypes.ContainsKey('platform')) { $archetypes['platform'].MgId }       else { '' }
    MG_NAME_LANDINGZONES                  = if ($archetypes.ContainsKey('landingzones')) { $archetypes['landingzones'].MgId }   else { '' }
    MG_NAME_CORP                          = if ($archetypes.ContainsKey('corp')) { $archetypes['corp'].MgId }           else { '' }
    MG_NAME_ONLINE                        = if ($archetypes.ContainsKey('online')) { $archetypes['online'].MgId }         else { '' }
    MG_NAME_CONNECTIVITY                  = if ($archetypes.ContainsKey('connectivity')) { $archetypes['connectivity'].MgId }   else { '' }
    MG_NAME_IDENTITY                      = if ($archetypes.ContainsKey('identity')) { $archetypes['identity'].MgId }       else { '' }
    MG_NAME_MANAGEMENT                    = if ($archetypes.ContainsKey('management')) { $archetypes['management'].MgId }     else { '' }
    MG_NAME_SECURITY                      = if ($archetypes.ContainsKey('security')) { $archetypes['security'].MgId }       else { '' }
    MG_NAME_SANDBOX                       = if ($archetypes.ContainsKey('sandbox')) { $archetypes['sandbox'].MgId }        else { '' }
    MG_NAME_DECOMMISSIONED                = if ($archetypes.ContainsKey('decommissioned')) { $archetypes['decommissioned'].MgId } else { '' }
    NETWORK_TYPE                          = 'hubnetworking'    # default — operatören väljer hubnetworking/virtualwan
    LOCATION                              = $location
    LOCATION_PRIMARY                      = $location
    MANAGEMENT_GROUP_ID                   = $tenantRootMgId
    LOCATION_SECONDARY                    = ''                 # ej härledbar — operatören fyller i
    ENABLE_TELEMETRY                      = 'true'             # default
    SECURITY_CONTACT_EMAIL                = $securityEmail
}

$outFile = Join-Path $OutputDirectory 'platform.json'
$platform | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding utf8
Write-Ok "Skrev: $outFile"

# -----------------------------------------------------------------------------
# Skriv en README-not med härledningsstatus per fält
# -----------------------------------------------------------------------------
$notesFile = Join-Path $OutputDirectory 'platform.json.notes.txt'
$notes = [System.Collections.Generic.List[string]]::new()
[void]$notes.Add("Härledningsstatus för platform.json")
[void]$notes.Add("Genererad: $(Get-Date -Format 'o')")
[void]$notes.Add("Källa:     AzGovViz-output vid $AzGovVizJsonPath")
[void]$notes.Add('')
[void]$notes.Add('Härlett från brownfield:')
[void]$notes.Add('  INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID  — från AzGovViz -ManagementGroupId')
[void]$notes.Add('  MANAGEMENT_GROUP_ID                    — int-roots mgParentId')
[void]$notes.Add('  MG_NAME_*                              — första barn med arketypsnamn under förväntad förälder')
[void]$notes.Add('  SUBSCRIPTION_ID_*                      — första prenumeration direkt under respektive MG')
[void]$notes.Add('  LOCATION / LOCATION_PRIMARY            — vanligast förekommande region i tilldelningsparametrar')
[void]$notes.Add('  SECURITY_CONTACT_EMAIL                 — Deploy-MDFC-Config-*.emailSecurityContact (fallback: Deploy-SvcHealth-BuiltIn)')
[void]$notes.Add('')
[void]$notes.Add('Default-värden — granska och justera vid behov:')
[void]$notes.Add('  PLATFORM_MODE      = "simple"            — engine-val, inte härledbart')
[void]$notes.Add('  NETWORK_TYPE       = "hubnetworking"     — operatören väljer hubnetworking eller virtualwan')
[void]$notes.Add('  ENABLE_TELEMETRY   = "true"              — engine-default')
[void]$notes.Add('  LOCATION_SECONDARY = ""                  — inte härledbart från brownfield; fyll i manuellt')
[void]$notes.Add('')
[void]$notes.Add('Före commit till tenant-konfigurationsrepot:')
[void]$notes.Add('  1. Granska tomma fält — vissa arketyp-MG:er kanske inte finns i just denna tenant')
[void]$notes.Add('  2. Verifiera att SUBSCRIPTION_ID_* stämmer när flera prenumerationer finns under samma MG')
[void]$notes.Add('  3. Bekräfta NETWORK_TYPE mot faktisk brownfield-topologi')
[void]$notes.Add('  4. Fyll i LOCATION_SECONDARY om geo-par är relevant')

$notes | Set-Content -Path $notesFile -Encoding utf8
Write-Info "Noter: $notesFile"

Write-Host ''
Write-Ok 'Klart.'