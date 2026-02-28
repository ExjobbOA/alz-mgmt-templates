#Requires -Version 7
<#
.SYNOPSIS
    ALZ Tenant Onboarding — one command to bootstrap a new Azure Landing Zone tenant.

.DESCRIPTION
    1. Creates GitHub environments (plan + apply) in the config repo
    2. Runs the bootstrap Bicep → deploys UAMIs + OIDC federated credentials
       + role assignments on the management group
    3. Captures deployment outputs (UAMI client IDs)
    4. Writes AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID
       as GitHub environment variables in both environments
    5. Updates config/platform.json and config/bootstrap/plumbing.bicepparam

.PARAMETER ConfigRepoPath
    Path to the alz-mgmt config repo on disk.
    Default: ../alz-mgmt (sibling of this templates repo).

.PARAMETER GithubOrg
    GitHub organisation name (e.g. ExjobbOA).
    Auto-detected from git remotes if not supplied.

.PARAMETER ModuleRepo
    Config repo name in GitHub (e.g. alz-mgmt).
    Auto-detected from the config repo's git remote if not supplied.

.PARAMETER TemplatesRepo
    Templates repo name (e.g. alz-mgmt-templates).
    Auto-detected from this repo's git remote if not supplied.

.PARAMETER BootstrapSubscriptionId
    Subscription ID where the identity resource group and UAMIs are created.

.PARAMETER ManagementGroupId
    Tenant root management group GUID (used for role assignments).

.PARAMETER Location
    Azure region for identity resources. Default: swedencentral.

.PARAMETER EnvPlan
    GitHub environment name for the plan/CI identity. Default: alz-mgmt-plan.

.PARAMETER EnvApply
    GitHub environment name for the apply/CD identity. Default: alz-mgmt-apply.

.PARAMETER WorkflowRefBranch
    Branch ref baked into OIDC subjects. Default: refs/heads/main.

.PARAMETER DryRun
    Print every action without making any changes.

.EXAMPLE
    ./scripts/onboard.ps1 `
        -BootstrapSubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ManagementGroupId       'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy'

.EXAMPLE
    ./scripts/onboard.ps1 -DryRun
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigRepoPath        = '',
    [string] $GithubOrg             = '',
    [string] $ModuleRepo            = '',
    [string] $TemplatesRepo         = '',
    [string] $BootstrapSubscriptionId = '',
    [string] $ManagementGroupId     = '',
    [string] $Location              = 'swedencentral',
    [string] $EnvPlan               = 'alz-mgmt-plan',
    [string] $EnvApply              = 'alz-mgmt-apply',
    [string] $WorkflowRefBranch     = 'refs/heads/main',
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Colours (suppressed when output is redirected) ───────────────────────────
$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step  ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" } else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info  ($msg) { if ($NoColor) { Write-Host "[INFO]  $msg" } else { Write-Host "`e[36m[INFO]`e[0m  $msg" } }
function Write-Ok    ($msg) { if ($NoColor) { Write-Host "[OK]    $msg" } else { Write-Host "`e[32m[OK]`e[0m    $msg" } }
function Write-Warn  ($msg) { if ($NoColor) { Write-Host "[WARN]  $msg" } else { Write-Host "`e[33m[WARN]`e[0m  $msg" } }
function Write-Fail  ($msg) { Write-Error "[ERROR] $msg" }
function Write-Dry   ($msg) { if ($NoColor) { Write-Host "[DRY]   $msg" } else { Write-Host "`e[33m[DRY]`e[0m   $msg" } }

# Script root = templates repo root
$TemplatesRoot = Split-Path $PSScriptRoot -Parent

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Get-GitRemoteField([string]$RepoPath, [string]$Field) {
    $url = git -C $RepoPath remote get-url origin 2>$null
    if (-not $url) { return '' }
    switch ($Field) {
        'org'  { if ($url -match 'github\.com[:/]([^/]+)/') { return $Matches[1] } }
        'repo' { if ($url -match '/([^/]+?)(\.git)?$')      { return $Matches[1] } }
    }
    return ''
}

function Read-Input([string]$Prompt, [string]$Default = '') {
    $display = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $input   = Read-Host $display
    if ($input -eq '' -and $Default -ne '') { return $Default }
    if ($input -eq '') { Write-Fail "$Prompt is required."; exit 1 }
    return $input
}

function Resolve-Input([ref]$Variable, [string]$Prompt, [string]$Default = '') {
    if ($Variable.Value -ne '') { return }
    if ($Default -ne '')        { $Variable.Value = $Default; return }
    $Variable.Value = Read-Input $Prompt $Default
}

# ─── Step 0: Prerequisites ────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-Step 'Checking prerequisites'

    foreach ($cmd in 'az', 'gh', 'git') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Fail "'$cmd' not found. Install it and re-run."
            exit 1
        }
    }
    Write-Ok 'az, gh, git — all present.'

    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { Write-Fail 'Not logged into Azure. Run: az login'; exit 1 }
    Write-Ok "Azure: logged in as $($account.user.name) (tenant $($account.tenantId))"

    $ghStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Not logged into GitHub CLI. Run: gh auth login'; exit 1 }
    Write-Ok 'GitHub CLI: authenticated.'
}

# ─── Step 1: Resolve inputs ───────────────────────────────────────────────────
function Resolve-Inputs {
    Write-Step 'Resolving inputs'

    # Config repo path
    if ($ConfigRepoPath -eq '') {
        $candidate = Join-Path $TemplatesRoot '../alz-mgmt'
        if (Test-Path $candidate) {
            $Script:ConfigRepoPath = (Resolve-Path $candidate).Path
        } else {
            $Script:ConfigRepoPath = Read-Input 'Path to the alz-mgmt config repo'
            if (-not (Test-Path $Script:ConfigRepoPath)) {
                Write-Fail "Config repo not found: $Script:ConfigRepoPath"; exit 1
            }
            $Script:ConfigRepoPath = (Resolve-Path $Script:ConfigRepoPath).Path
        }
    } else {
        if (-not (Test-Path $ConfigRepoPath)) {
            Write-Fail "Config repo not found: $ConfigRepoPath"; exit 1
        }
        $Script:ConfigRepoPath = (Resolve-Path $ConfigRepoPath).Path
    }
    Write-Info "Config repo: $Script:ConfigRepoPath"

    # Auto-detect from git remotes
    if ($TemplatesRepo -eq '') { $Script:TemplatesRepo = Get-GitRemoteField $TemplatesRoot 'repo' }
    if ($TemplatesRepo -eq '') { $Script:TemplatesRepo = 'alz-mgmt-templates' }

    if ($GithubOrg -eq '') { $Script:GithubOrg = Get-GitRemoteField $TemplatesRoot 'org' }
    if ($GithubOrg -eq '') { $Script:GithubOrg = Get-GitRemoteField $Script:ConfigRepoPath 'org' }

    if ($ModuleRepo -eq '') { $Script:ModuleRepo = Get-GitRemoteField $Script:ConfigRepoPath 'repo' }

    # Load defaults from platform.json
    $platformJson = Join-Path $Script:ConfigRepoPath 'config/platform.json'
    if (Test-Path $platformJson) {
        Write-Info 'Loading defaults from config/platform.json...'
        $p = Get-Content $platformJson | ConvertFrom-Json
        if ($ManagementGroupId     -eq '' -and $p.MANAGEMENT_GROUP_ID)        { $Script:ManagementGroupId     = $p.MANAGEMENT_GROUP_ID }
        if ($BootstrapSubscriptionId -eq '' -and $p.SUBSCRIPTION_ID_MANAGEMENT) { $Script:BootstrapSubscriptionId = $p.SUBSCRIPTION_ID_MANAGEMENT }
        if ($Location -eq 'swedencentral' -and $p.LOCATION)                   { $Script:Location              = $p.LOCATION }
    }

    # Prompt for anything still missing (check Script: vars, which may have been populated above)
    if ($Script:GithubOrg              -eq '') { $Script:GithubOrg              = Read-Input 'GitHub organisation'               }
    if ($Script:ModuleRepo             -eq '') { $Script:ModuleRepo             = Read-Input 'Config repo name (in that org)'    }
    if ($Script:BootstrapSubscriptionId -eq '') { $Script:BootstrapSubscriptionId = Read-Input 'Bootstrap subscription ID'        }
    if ($Script:ManagementGroupId      -eq '') { $Script:ManagementGroupId      = Read-Input 'Tenant root management group GUID' }
    if ($Script:Location               -eq '') { $Script:Location               = Read-Input 'Azure region' 'swedencentral'      }
}

# ─── Step 2: Confirm plan ─────────────────────────────────────────────────────
function Confirm-Plan {
    Write-Step 'Plan'
    Write-Host ''
    Write-Host "  Config repo path    : $Script:ConfigRepoPath"
    Write-Host "  GitHub org/repo     : $Script:GithubOrg/$Script:ModuleRepo"
    Write-Host "  Templates repo      : $Script:TemplatesRepo"
    Write-Host "  Bootstrap sub ID    : $Script:BootstrapSubscriptionId"
    Write-Host "  Root MG GUID        : $Script:ManagementGroupId"
    Write-Host "  Azure region        : $Script:Location"
    Write-Host "  GitHub environments : $Script:EnvPlan (plan)  $Script:EnvApply (apply)"
    Write-Host "  Workflow branch     : $Script:WorkflowRefBranch"
    Write-Host ''

    if ($DryRun) { Write-Warn 'DRY RUN — no changes will be made.'; return }

    $confirm = Read-Host 'Proceed with onboarding? [y/N]'
    if ($confirm -notmatch '^[Yy]$') { Write-Info 'Aborted.'; exit 0 }
}

# ─── Step 3: Create GitHub environments ──────────────────────────────────────
function New-GitHubEnvironments {
    Write-Step 'Creating GitHub environments'
    foreach ($env in $Script:EnvPlan, $Script:EnvApply) {
        if ($DryRun) {
            Write-Dry "gh api PUT repos/$Script:GithubOrg/$Script:ModuleRepo/environments/$env"
            continue
        }
        Write-Info "  Creating environment '$env'..."
        gh api --method PUT "repos/$Script:GithubOrg/$Script:ModuleRepo/environments/$env" | Out-Null
        Write-Ok "  '$env' ready."
    }
}

# ─── Step 4: Configure OIDC subject claim ────────────────────────────────────
function Set-OidcSubjectClaim {
    Write-Step 'Configuring OIDC subject claim (include job_workflow_ref)'

    # By default GitHub's OIDC sub for environment-based jobs is:
    #   repo:ORG/REPO:environment:ENV
    # Our FICs require job_workflow_ref in the subject. This API call opts the
    # repo into a custom subject format that appends it.
    if ($DryRun) {
        Write-Dry "Would configure OIDC sub: repos/$Script:GithubOrg/$Script:ModuleRepo/actions/oidc/customization/sub"
        Write-Dry '  use_default=false, include_claim_keys=[repo, context, job_workflow_ref]'
        return
    }

    $body     = '{"use_default":false,"include_claim_keys":["repo","context","job_workflow_ref"]}'
    $tempFile = [System.IO.Path]::GetTempFileName()
    $body | Set-Content $tempFile -Encoding UTF8

    try {
        gh api --method PUT "repos/$Script:GithubOrg/$Script:ModuleRepo/actions/oidc/customization/sub" `
            --input $tempFile | Out-Null
    } finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'OIDC subject configuration failed. Set it manually:'
        Write-Warn "  gh api --method PUT repos/$Script:GithubOrg/$Script:ModuleRepo/actions/oidc/customization/sub --input <json-file>"
        Write-Warn '  JSON: {"use_default":false,"include_claim_keys":["repo","context","job_workflow_ref"]}'
        return
    }

    Write-Ok 'OIDC subject claim configured: sub will include repo + context + job_workflow_ref.'
}

# ─── Step 5: Run bootstrap Bicep ─────────────────────────────────────────────
function Invoke-Bootstrap {
    Write-Step 'Running bootstrap Bicep deployment'

    $templateFile = Join-Path $TemplatesRoot 'bootstrap/plumbing/main.json'
    if (-not (Test-Path $templateFile)) {
        Write-Fail "Bootstrap template not found: $templateFile"; exit 1
    }

    # Build the parameter object and convert to ARM parameters JSON
    $paramObj = [ordered]@{
        bootstrapSubscriptionId = @{ value = $Script:BootstrapSubscriptionId }
        location                = @{ value = $Script:Location }
        githubOrg               = @{ value = $Script:GithubOrg }
        moduleRepo              = @{ value = $Script:ModuleRepo }
        templatesRepo           = @{ value = $Script:TemplatesRepo }
        envPlan                 = @{ value = $Script:EnvPlan }
        envApply                = @{ value = $Script:EnvApply }
        workflowRefBranch       = @{ value = $Script:WorkflowRefBranch }
    }
    $paramsJson = $paramObj | ConvertTo-Json -Depth 5 -Compress

    if ($DryRun) {
        Write-Dry 'Would run: az deployment mg create ...'
        Write-Host "    --name alz-bootstrap"
        Write-Host "    --management-group-id '$Script:ManagementGroupId'"
        Write-Host "    --location '$Script:Location'"
        Write-Host "    --template-file '$templateFile'"
        Write-Host "    --parameters '<json>'"
        $Script:PlanClientId  = '00000000-dry-run-plan-000000000000'
        $Script:ApplyClientId = '00000000-dry-run-apply-00000000000'
        $Script:IdentityRg    = "rg-alz-mgmt-identity-$Script:Location-1"
        return
    }

    Write-Info "  Deploying to management group: $Script:ManagementGroupId"
    Write-Info "  (This may take 2–5 minutes)"

    # Write params to a temp file to avoid PowerShell quote-stripping when passing
    # JSON strings to native commands on Windows.
    $tempParamsFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')
    $paramsJson | Set-Content -Path $tempParamsFile -Encoding UTF8

    try {
        $result = az deployment mg create `
            --name            'alz-bootstrap' `
            --management-group-id $Script:ManagementGroupId `
            --location        $Script:Location `
            --template-file   $templateFile `
            --parameters      "@$tempParamsFile" `
            --output json | ConvertFrom-Json
    } finally {
        Remove-Item $tempParamsFile -ErrorAction SilentlyContinue
    }

    if ($LASTEXITCODE -ne 0) { Write-Fail 'Bootstrap deployment failed.'; exit 1 }

    $outputs = $result.properties.outputs
    $Script:PlanClientId  = $outputs.planClientId.value
    $Script:ApplyClientId = $outputs.applyClientId.value
    $Script:IdentityRg    = $outputs.identityResourceGroup.value

    if (-not $Script:PlanClientId  -or $Script:PlanClientId  -eq 'null') { Write-Fail 'planClientId missing from deployment output'; exit 1 }
    if (-not $Script:ApplyClientId -or $Script:ApplyClientId -eq 'null') { Write-Fail 'applyClientId missing from deployment output'; exit 1 }

    Write-Ok 'Bootstrap deployment complete.'
    Write-Ok "  Identity RG    : $Script:IdentityRg"
    Write-Ok "  Plan clientId  : $Script:PlanClientId"
    Write-Ok "  Apply clientId : $Script:ApplyClientId"
}

# ─── Step 6: Get Azure tenant ID ─────────────────────────────────────────────
function Get-AzureTenantId {
    Write-Step 'Fetching Azure tenant ID'
    if ($DryRun) {
        $Script:AzureTenantId = '00000000-dry-run-tenant-0000000000'
        Write-Dry 'Skipping az account show'
        return
    }
    $Script:AzureTenantId = az account show --query tenantId -o tsv
    Write-Ok "Tenant ID: $Script:AzureTenantId"
}

# ─── Step 7: Write GitHub environment variables ───────────────────────────────
function Set-GitHubEnvVars {
    Write-Step 'Writing GitHub environment variables'

    function Set-EnvVar([string]$Env, [string]$Name, [string]$Value) {
        Write-Info "  $Env : $Name"
        if ($DryRun) { Write-Dry "gh variable set $Name --env $Env"; return }
        gh variable set $Name `
            --repo "$Script:GithubOrg/$Script:ModuleRepo" `
            --env  $Env `
            --body $Value
    }

    Set-EnvVar $Script:EnvPlan  'AZURE_CLIENT_ID'       $Script:PlanClientId
    Set-EnvVar $Script:EnvPlan  'AZURE_TENANT_ID'        $Script:AzureTenantId
    Set-EnvVar $Script:EnvPlan  'AZURE_SUBSCRIPTION_ID'  $Script:BootstrapSubscriptionId

    Set-EnvVar $Script:EnvApply 'AZURE_CLIENT_ID'       $Script:ApplyClientId
    Set-EnvVar $Script:EnvApply 'AZURE_TENANT_ID'        $Script:AzureTenantId
    Set-EnvVar $Script:EnvApply 'AZURE_SUBSCRIPTION_ID'  $Script:BootstrapSubscriptionId

    Write-Ok 'All environment variables written.'
}

# ─── Step 8: Update config/platform.json ─────────────────────────────────────
function Update-PlatformJson {
    Write-Step 'Updating config/platform.json'

    $platformFile = Join-Path $Script:ConfigRepoPath 'config/platform.json'
    if (-not (Test-Path $platformFile)) { Write-Warn 'config/platform.json not found — skipping.'; return }

    if ($DryRun) {
        Write-Dry "Would update MANAGEMENT_GROUP_ID, LOCATION, LOCATION_PRIMARY,"
        Write-Dry "SUBSCRIPTION_ID_MANAGEMENT in $platformFile"
        return
    }

    $p = Get-Content $platformFile | ConvertFrom-Json

    $p.MANAGEMENT_GROUP_ID   = $Script:ManagementGroupId
    $p.LOCATION              = $Script:Location
    $p.LOCATION_PRIMARY      = $Script:Location

    $p.SUBSCRIPTION_ID_MANAGEMENT = $Script:BootstrapSubscriptionId

    $isSimple = ($p.PSObject.Properties.Name -contains 'PLATFORM_MODE') -and ($p.PLATFORM_MODE -eq 'simple')

    if ($isSimple) {
        # Simple mode: single SUBSCRIPTION_ID_PLATFORM covers all platform subs
        if ($p.PSObject.Properties.Name -contains 'SUBSCRIPTION_ID_PLATFORM') {
            $p.SUBSCRIPTION_ID_PLATFORM = $Script:BootstrapSubscriptionId
        }
    } else {
        # Full mode: update the four individual platform subscription IDs if they were all identical
        $hasAll = ($p.PSObject.Properties.Name -contains 'SUBSCRIPTION_ID_CONNECTIVITY') -and
                  ($p.PSObject.Properties.Name -contains 'SUBSCRIPTION_ID_IDENTITY')     -and
                  ($p.PSObject.Properties.Name -contains 'SUBSCRIPTION_ID_SECURITY')
        if ($hasAll) {
            $allSame = ($p.SUBSCRIPTION_ID_MANAGEMENT -eq $p.SUBSCRIPTION_ID_CONNECTIVITY) -and
                       ($p.SUBSCRIPTION_ID_MANAGEMENT -eq $p.SUBSCRIPTION_ID_IDENTITY)     -and
                       ($p.SUBSCRIPTION_ID_MANAGEMENT -eq $p.SUBSCRIPTION_ID_SECURITY)
            if ($allSame) {
                $p.SUBSCRIPTION_ID_CONNECTIVITY = $Script:BootstrapSubscriptionId
                $p.SUBSCRIPTION_ID_IDENTITY     = $Script:BootstrapSubscriptionId
                $p.SUBSCRIPTION_ID_SECURITY     = $Script:BootstrapSubscriptionId
            } else {
                Write-Info '  SUBSCRIPTION_ID_CONNECTIVITY/IDENTITY/SECURITY were already different — only MANAGEMENT was updated.'
                Write-Info '  Review and adjust the others manually if needed.'
            }
        }
    }

    $p | ConvertTo-Json -Depth 5 | Set-Content $platformFile -Encoding UTF8
    Write-Ok 'config/platform.json updated.'
}

# ─── Step 9: Update config/bootstrap/plumbing.bicepparam ──────────────────────
function Update-BootstrapBicepparam {
    Write-Step 'Updating config/bootstrap/plumbing.bicepparam'

    $paramFile = Join-Path $Script:ConfigRepoPath 'config/bootstrap/plumbing.bicepparam'
    if (-not (Test-Path $paramFile)) { Write-Warn 'config/bootstrap/plumbing.bicepparam not found — skipping.'; return }

    if ($DryRun) {
        Write-Dry "Would update bootstrapSubscriptionId, location, githubOrg,"
        Write-Dry "moduleRepo, templatesRepo, envPlan, envApply in $paramFile"
        return
    }

    $content = Get-Content $paramFile -Raw

    $replacements = [ordered]@{
        "param bootstrapSubscriptionId = '.*'" = "param bootstrapSubscriptionId = '$Script:BootstrapSubscriptionId'"
        "param location = '.*'"                = "param location = '$Script:Location'"
        "param githubOrg = '.*'"               = "param githubOrg = '$Script:GithubOrg'"
        "param moduleRepo = '.*'"              = "param moduleRepo = '$Script:ModuleRepo'"
        "param templatesRepo = '.*'"           = "param templatesRepo = '$Script:TemplatesRepo'"
        "param envPlan = '.*'"                 = "param envPlan = '$Script:EnvPlan'"
        "param envApply = '.*'"                = "param envApply = '$Script:EnvApply'"
    }

    foreach ($pattern in $replacements.Keys) {
        $content = $content -replace $pattern, $replacements[$pattern]
    }

    Set-Content $paramFile $content -Encoding UTF8 -NoNewline
    Write-Ok 'config/bootstrap/plumbing.bicepparam updated.'
}

# ─── Summary ──────────────────────────────────────────────────────────────────
function Write-Summary {
    Write-Host ''
    Write-Host '══════════════════════════════════════════════════════════'
    Write-Host '  Onboarding complete!'
    Write-Host '══════════════════════════════════════════════════════════'
    Write-Host ''
    Write-Host '  Azure resources:'
    Write-Host "    Identity resource group : $Script:IdentityRg"
    Write-Host "    Plan UAMI client ID     : $Script:PlanClientId"
    Write-Host "    Apply UAMI client ID    : $Script:ApplyClientId"
    Write-Host "    Tenant ID               : $Script:AzureTenantId"
    Write-Host ''
    Write-Host "  GitHub ($Script:GithubOrg/$Script:ModuleRepo):"
    Write-Host "    '$Script:EnvPlan'  → AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID"
    Write-Host "    '$Script:EnvApply' → AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID"
    Write-Host ''
    Write-Host '  Config files updated:'
    Write-Host "    $Script:ConfigRepoPath\config\platform.json"
    Write-Host "    $Script:ConfigRepoPath\config\bootstrap\plumbing.bicepparam"
    Write-Host ''
    Write-Host '  Next steps:'
    Write-Host "    1. cd $Script:ConfigRepoPath"
    Write-Host '    2. Review config\platform.json — adjust SUBSCRIPTION_ID_CONNECTIVITY/'
    Write-Host '       IDENTITY/SECURITY if they differ from Management'
    Write-Host '    3. git add -p && git commit && git push → open PR to trigger CI'
    Write-Host '    4. Once CI passes, run CD with governance-int-root=true'
    Write-Host ''
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Script-scoped mutable state (populated by steps)
$Script:ConfigRepoPath         = $ConfigRepoPath
$Script:GithubOrg              = $GithubOrg
$Script:ModuleRepo             = $ModuleRepo
$Script:TemplatesRepo          = $TemplatesRepo
$Script:BootstrapSubscriptionId = $BootstrapSubscriptionId
$Script:ManagementGroupId      = $ManagementGroupId
$Script:Location               = $Location
$Script:EnvPlan                = $EnvPlan
$Script:EnvApply               = $EnvApply
$Script:WorkflowRefBranch      = $WorkflowRefBranch
$Script:PlanClientId           = ''
$Script:ApplyClientId          = ''
$Script:IdentityRg             = ''
$Script:AzureTenantId          = ''

Write-Host ''
if ($NoColor) { Write-Host 'ALZ Tenant Onboarding' } else { Write-Host "`e[1mALZ Tenant Onboarding`e[0m" }
if ($DryRun)  { Write-Warn '(dry run — no changes will be made)' }
Write-Host ''

Test-Prerequisites
Resolve-Inputs
Confirm-Plan
New-GitHubEnvironments
Set-OidcSubjectClaim
Invoke-Bootstrap
Get-AzureTenantId
Set-GitHubEnvVars
Update-PlatformJson
Update-BootstrapBicepparam

if (-not $DryRun) { Write-Summary } else { Write-Host ''; Write-Warn 'Dry run complete — no changes were made.' }
