# Brownfield Demo Day — Complete Plan

## Part 1: Code Changes (morning, ~1-2 hours)

### 1A. Engine repo: MG name env vars in pre-create step

**File:** `.github/workflows/cd-template.yaml` — the "Pre-create ALZ MG hierarchy (cold-start)" step (line ~482-545)

**Change:** Replace hardcoded MG names with env var reads that fall back to defaults.

Current:
```powershell
$mgs = @(
    [pscustomobject]@{ Name = $intRoot;         Parent = $tenantRg;      SubMgOnly = $false },
    [pscustomobject]@{ Name = 'landingzones';   Parent = $intRoot;       SubMgOnly = $false },
    [pscustomobject]@{ Name = 'platform';       Parent = $intRoot;       SubMgOnly = $false },
    [pscustomobject]@{ Name = 'sandbox';        Parent = $intRoot;       SubMgOnly = $false },
    [pscustomobject]@{ Name = 'decommissioned'; Parent = $intRoot;       SubMgOnly = $false },
    [pscustomobject]@{ Name = 'corp';           Parent = 'landingzones'; SubMgOnly = $false },
    [pscustomobject]@{ Name = 'online';         Parent = 'landingzones'; SubMgOnly = $false },
    [pscustomobject]@{ Name = 'connectivity';   Parent = 'platform';     SubMgOnly = $true },
    [pscustomobject]@{ Name = 'identity';       Parent = 'platform';     SubMgOnly = $true },
    [pscustomobject]@{ Name = 'management';     Parent = 'platform';     SubMgOnly = $true },
    [pscustomobject]@{ Name = 'security';       Parent = 'platform';     SubMgOnly = $true }
)
```

New:
```powershell
# Read MG names from env vars (set via platform.json → bicep-variables action)
# Fall back to engine defaults if not set
$mgNameLandingzones   = if ($env:MG_NAME_LANDINGZONES)   { $env:MG_NAME_LANDINGZONES }   else { 'landingzones' }
$mgNamePlatform       = if ($env:MG_NAME_PLATFORM)       { $env:MG_NAME_PLATFORM }       else { 'platform' }
$mgNameSandbox        = if ($env:MG_NAME_SANDBOX)        { $env:MG_NAME_SANDBOX }        else { 'sandbox' }
$mgNameDecommissioned = if ($env:MG_NAME_DECOMMISSIONED) { $env:MG_NAME_DECOMMISSIONED } else { 'decommissioned' }
$mgNameCorp           = if ($env:MG_NAME_CORP)           { $env:MG_NAME_CORP }           else { 'corp' }
$mgNameOnline         = if ($env:MG_NAME_ONLINE)         { $env:MG_NAME_ONLINE }         else { 'online' }
$mgNameConnectivity   = if ($env:MG_NAME_CONNECTIVITY)   { $env:MG_NAME_CONNECTIVITY }   else { 'connectivity' }
$mgNameIdentity       = if ($env:MG_NAME_IDENTITY)       { $env:MG_NAME_IDENTITY }       else { 'identity' }
$mgNameManagement     = if ($env:MG_NAME_MANAGEMENT)     { $env:MG_NAME_MANAGEMENT }     else { 'management' }
$mgNameSecurity       = if ($env:MG_NAME_SECURITY)       { $env:MG_NAME_SECURITY }       else { 'security' }

$mgs = @(
    [pscustomobject]@{ Name = $intRoot;              Parent = $tenantRg;            SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameLandingzones;   Parent = $intRoot;             SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNamePlatform;       Parent = $intRoot;             SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameSandbox;        Parent = $intRoot;             SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameDecommissioned; Parent = $intRoot;             SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameCorp;           Parent = $mgNameLandingzones;  SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameOnline;         Parent = $mgNameLandingzones;  SubMgOnly = $false },
    [pscustomobject]@{ Name = $mgNameConnectivity;   Parent = $mgNamePlatform;      SubMgOnly = $true },
    [pscustomobject]@{ Name = $mgNameIdentity;       Parent = $mgNamePlatform;      SubMgOnly = $true },
    [pscustomobject]@{ Name = $mgNameManagement;     Parent = $mgNamePlatform;      SubMgOnly = $true },
    [pscustomobject]@{ Name = $mgNameSecurity;       Parent = $mgNamePlatform;      SubMgOnly = $true }
)
```

**Why:** Without this, the pre-create step creates new MGs with default names alongside existing brownfield MGs. This is the only engine repo change needed — everything else flows from platform.json via the bicep-variables action.

**Test:** Greenfield tenants that don't set MG_NAME_* vars get the same behavior as before (defaults). Brownfield tenants set these in platform.json and the pre-create step uses the existing MG names.


### 1B. Compare report: MG name overrides in Section 6

**File:** `scripts/Compare-BrownfieldState.ps1` — Section 6

**Add after the platform subscription mapping block:**

Map the brownfield MG hierarchy names to the config values the operator needs. Walk the hierarchy from the export, normalize each MG name, compare to engine defaults, and output overrides where they differ.

Engine defaults for reference:
- int-root: `alz`
- platform: `platform`
- landingzones: `landingzones`
- corp: `corp`
- online: `online`
- sandbox: `sandbox`
- decommissioned: `decommissioned`

Expected output for Sylaviken:
```
  Management group name configuration:
    INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID: ALZ
    MG_NAME_PLATFORM:       ALZ-platform        (engine default: platform)
    MG_NAME_LANDINGZONES:   ALZ-landingzones     (engine default: landingzones)
    MG_NAME_CORP:           ALZ-corp             (engine default: corp)
    MG_NAME_ONLINE:         ALZ-online           (engine default: online)
    MG_NAME_SANDBOX:        ALZ-sandboxes        (engine default: sandbox)
    MG_NAME_DECOMMISSIONED: ALZ-decommissioned   (engine default: decommissioned)
```

Also include bicepparam override hints:
```
  Bicepparam overrides required (set managementGroupName and managementGroupParentId):
    config/core/governance/mgmt-groups/int-root.bicepparam      → managementGroupName: 'ALZ'
    config/core/governance/mgmt-groups/platform.bicepparam       → managementGroupName: 'ALZ-platform', managementGroupParentId: 'ALZ'
    config/core/governance/mgmt-groups/landingzones.bicepparam   → managementGroupName: 'ALZ-landingzones', managementGroupParentId: 'ALZ'
    ...etc for each MG
```

If ALL brownfield MG names match engine defaults, just print:
```
  Management group names: all match engine defaults — no overrides needed
```


### 1C. Compare report: tenant ID and MG root ID in Section 6

**File:** `scripts/Compare-BrownfieldState.ps1` — Section 6

Add at the top of Section 6, before the existing JSON block:
```
  Core identifiers:
    MANAGEMENT_GROUP_ID (tenant root): c785e463-29cf-46e6-9b1d-ae17db0a6ac4
    INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID: ALZ
```

These come from `$export.TenantId` and `$export.RootManagementGroupId`. The operator needs both for onboard.ps1 and platform.json.


### 1D. Compare report: logging resource guidance in Section 6

**File:** `scripts/Compare-BrownfieldState.ps1` — Section 6

Expand the hub networking section to include logging resource guidance. The data is already in Section 5 — just reference it in Section 6:

```
  Logging resources (from infrastructure scan):
    Existing LAW: ALZ-law (in rg: ALZ-mgmt, sub: 93ff5894-...)
    Existing AA:  ALZ-aauto (in rg: ALZ-mgmt, sub: 93ff5894-...)
[WARN] Engine defaults would create new resources (law-alz-swedencentral, aa-alz-swedencentral)
       To reuse existing resources, set in core/logging/main.bicepparam:
         parLogAnalyticsWorkspaceName: 'ALZ-law'
         parAutomationAccountName: 'ALZ-aauto'
         parMgmtLoggingResourceGroup: 'ALZ-mgmt'
```

If no naming mismatch exists, don't show the warning.


### 1E. Delete discover.ps1

**File:** `scripts/discover.ps1` — delete it entirely.


## Part 2: Deploy Portal Accelerator on Test Tenant (~30-60 min)

1. Log into Azure portal with your test tenant (the one you have Owner on)
2. Go to https://aka.ms/alz/portal
3. Deploy the portal accelerator with:
   - Single platform subscription (PLATFORM_MODE simple)
   - Sweden Central region
   - Enable AMBA if the option is available
   - Let it create the standard MG hierarchy
4. Wait for deployment to complete
5. Verify: check MG hierarchy in portal, confirm policies are assigned, note the MG names it created

**Important:** Write down the exact MG names the portal creates. These are what you'll need to configure in platform.json.


## Part 3: Run Brownfield Workflow (~2-3 hours)

### 3A. Export the test tenant state

```powershell
Connect-AzAccount -Tenant "<test-tenant-id>"
./scripts/Export-BrownfieldState.ps1 `
    -OutputFile "../state-snapshots/state-test-brownfield.json" `
    -RootManagementGroupId "<portal-created-int-root-mg-name>"
```

### 3B. Run the compare report

```powershell
./scripts/Compare-BrownfieldState.ps1 `
    -BrownfieldExport ../state-snapshots/state-test-brownfield.json `
    -Detailed
```

Save the output — this is your "before" artifact for the thesis.

### 3C. Create the tenant config repo

1. Create a new config repo from the alz-mgmt template:
   ```
   gh repo create ExjobbOA/alz-mgmt-test --template ExjobbOA/alz-mgmt --private
   gh repo clone ExjobbOA/alz-mgmt-test ../alz-mgmt-test
   ```

2. Populate `config/platform.json` using the compare report Section 6 output:
   - MANAGEMENT_GROUP_ID (tenant root)
   - INTERMEDIATE_ROOT_MANAGEMENT_GROUP_ID
   - LOCATION / LOCATION_PRIMARY
   - SUBSCRIPTION_ID_MANAGEMENT (and others if applicable)
   - PLATFORM_MODE
   - SECURITY_CONTACT_EMAIL
   - MG_NAME_* overrides (from the new Section 6 output)
   - STACK_PREFIX (optional, e.g. "test-")

3. Update the bicepparam files with MG name overrides:
   - Each `config/core/governance/mgmt-groups/*.bicepparam` needs `managementGroupName` and `managementGroupParentId` set to match the brownfield MG names
   - `config/core/logging/main.bicepparam` needs LAW/AA/RG names set to match existing resources (or accept duplicates)

### 3D. Bootstrap the tenant

```powershell
az login --tenant "<test-tenant-id>"
gh auth login

./scripts/onboard.ps1 `
    -ConfigRepoPath '../alz-mgmt-test' `
    -BootstrapSubscriptionId '<platform-sub-id>' `
    -ManagementGroupId '<tenant-root-mg-guid>'
```

This creates OIDC identities, GitHub environments, and updates platform.json.

### 3E. Deploy

1. Commit and push the config repo
2. Trigger the CD workflow (or let it trigger from push)
3. Watch the pipeline — the pre-create step should skip all MGs ("already exists"), and each governance stack should deploy successfully

### 3F. Verify

After deployment completes:

1. **MG hierarchy:** No duplicate MGs created. Existing MGs unchanged.

2. **Policy definitions:** Run the export again and compare:
   ```powershell
   ./scripts/Export-BrownfieldState.ps1 `
       -OutputFile "../state-snapshots/state-test-after-adoption.json" `
       -RootManagementGroupId "<int-root-mg-name>"
   
   ./scripts/Compare-BrownfieldState.ps1 `
       -BrownfieldExport ../state-snapshots/state-test-after-adoption.json `
       -Detailed
   ```
   The 89 rule mismatches should now be 0 (or close to 0) — the engine overwrote them.

3. **AMBA:** Still present, untouched (DetachAll means the stacks don't manage them).

4. **Non-standard assignments:** Still present (`Deploy-ASC-Monitoring`, `Deploy-AKS-Policy`, `Deploy-Log-Analytics`).

5. **Deprecated definitions:** Still present (DetachAll, not managed by stacks).

6. **Logging resources:** Check whether duplicates were created or existing resources were adopted, depending on how you configured the bicepparam.

7. **Deployment stacks:** Run `Get-AzManagementGroupDeploymentStack -ManagementGroupId <int-root>` to see the stacks the engine created. They should show all the governance resources as managed.


## Part 4: Capture Evidence (~30 min)

- Screenshot the pipeline run (green checks)
- Save the before/after compare reports
- Save the state snapshot JSONs
- Screenshot the MG hierarchy in the portal (no duplicates)
- Screenshot a policy definition showing the updated version
- Document any issues you hit and how you resolved them

This is your iteration 2 empirical data. It directly answers: "Can the platform safely integrate an existing portal-deployed ALZ into IaC governance without disrupting workloads?"
