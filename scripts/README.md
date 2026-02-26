# scripts/

| Script | Purpose |
|--------|---------|
| [onboard.ps1](#onboardps1--tenant-onboarding) | Bootstrap a new tenant — one command |
| [cleanup.ps1](#cleanupps1--tenant-cleanup) | Tear down a previous deployment so you can re-onboard |

---

## Tool requirements

The two scripts have different dependencies. Install everything once, then use as needed.

```powershell
# Runtime
winget install Microsoft.PowerShell   # PS 7+ — required by both scripts

# Azure CLI  (used by onboard.ps1 for the bootstrap ARM deployment)
winget install Microsoft.AzureCLI

# Az PowerShell module  (used by cleanup.ps1 for Deployment Stack cmdlets)
# Run in a pwsh window after installing PS7:
Install-Module -Name Az -Force -AllowClobber -Scope CurrentUser

# GitHub CLI  (used by onboard.ps1 only — not needed for cleanup)
winget install GitHub.cli
```

> **Reopen your terminal after winget installs** so the PATH update takes effect.

### Authentication — two separate sessions

`az` CLI and the `Az` PowerShell module maintain their own login state independently.

| Script | Auth required |
|--------|--------------|
| `onboard.ps1` | `az login --tenant <id>` **+** `gh auth login` |
| `cleanup.ps1` | `Connect-AzAccount -Tenant <id>` |

```powershell
# For onboard.ps1
az login --tenant <tenant-guid>
az account set --subscription <subscription-id>
gh auth login

# For cleanup.ps1
Connect-AzAccount -Tenant <tenant-guid>
Set-AzContext -Subscription <subscription-id>
```

If your tenant enforces MFA, use `az login --tenant <id>` (not plain `az login`) to force the
interactive browser flow where the MFA prompt will appear.

---

## onboard.ps1 — Tenant Onboarding

Bootstraps a new Azure Landing Zone tenant end-to-end in a single command.

> **Scope:** The script handles the Azure identity setup and GitHub wiring.
> It assumes the config repo (`alz-mgmt`) already exists on GitHub and is cloned locally.
> See [Before you run](#before-you-run) below.
>
> ⚠️ *Automatic repo creation (from template) is planned but not yet implemented.*

### What it does

| Step | Action |
|------|--------|
| 1 | Auto-detects `GithubOrg`, `ModuleRepo`, `TemplatesRepo` from git remotes; loads defaults from `config/platform.json`; prompts interactively for anything still missing |
| 2 | Prints the full plan and asks for confirmation |
| 3 | Creates the two GitHub environments (`alz-mgmt-plan`, `alz-mgmt-apply`) in the config repo |
| 4 | Runs `az deployment mg create` using the compiled `bootstrap/plumbing/main.json` — deploys UAMIs, OIDC federated credentials, and role assignments on the management group |
| 5 | Reads the `tenantId` from `az account show` |
| 6 | Writes `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` as GitHub **environment variables** in both environments |
| 7 | Updates `config/platform.json` in the config repo |
| 8 | Updates `config/bootstrap/plumbing.bicepparam` in the config repo |

After the script finishes, commit the updated config files, push, and run the CD workflow.

### Before you run

The script expects the tenant config repo to **already exist** locally and on GitHub.
If you're onboarding from scratch:

```powershell
# 1. Create a new config repo from the alz-mgmt template
gh repo create <org>/<new-repo-name> --template ExjobbOA/alz-mgmt --private

# 2. Clone it next to the templates repo
gh repo clone <org>/<new-repo-name> ../alz-mgmt   # or your chosen path

# 3. Run the onboarding script
./scripts/onboard.ps1 -ConfigRepoPath '../alz-mgmt' ...
```

> Future: `-CreateRepo` flag will automate steps 1–2.

### Usage

```powershell
# Minimal — prompts for anything not auto-detected
./scripts/onboard.ps1 `
    -BootstrapSubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ManagementGroupId       'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy'

# Preview every action without making any changes
./scripts/onboard.ps1 -DryRun

# Fully non-interactive (CI/automation)
./scripts/onboard.ps1 `
    -ConfigRepoPath          '../alz-mgmt' `
    -GithubOrg               'ExjobbOA' `
    -ModuleRepo              'alz-mgmt' `
    -BootstrapSubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ManagementGroupId       'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy' `
    -Location                'swedencentral'
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ConfigRepoPath` | No | `../alz-mgmt` | Path to the tenant config repo on disk |
| `-GithubOrg` | No* | git remote | GitHub organisation name |
| `-ModuleRepo` | No* | git remote | Config repo name in GitHub |
| `-TemplatesRepo` | No* | git remote | Templates repo name in GitHub |
| `-BootstrapSubscriptionId` | **Yes** | `platform.json` | Subscription where identity RG + UAMIs are created |
| `-ManagementGroupId` | **Yes** | `platform.json` | Tenant root management group GUID |
| `-Location` | No | `swedencentral` | Azure region for identity resources |
| `-EnvPlan` | No | `alz-mgmt-plan` | GitHub environment name for the plan/CI identity |
| `-EnvApply` | No | `alz-mgmt-apply` | GitHub environment name for the apply/CD identity |
| `-WorkflowRefBranch` | No | `refs/heads/main` | Branch ref baked into OIDC subjects |
| `-DryRun` | No | — | Print every action; make no changes |

\* Auto-detected from git remotes; prompted interactively if detection fails.

### What gets written to GitHub

Both environments receive three **variables** (not secrets — OIDC needs no secret):

| Variable | Plan env value | Apply env value |
|----------|---------------|-----------------|
| `AZURE_CLIENT_ID` | Plan UAMI client ID | Apply UAMI client ID |
| `AZURE_TENANT_ID` | Azure tenant GUID | Azure tenant GUID |
| `AZURE_SUBSCRIPTION_ID` | Bootstrap subscription ID | Bootstrap subscription ID |

### What gets updated in the config repo

**`config/platform.json`**
- `MANAGEMENT_GROUP_ID`, `LOCATION`, `LOCATION_PRIMARY`
- `SUBSCRIPTION_ID_MANAGEMENT` (and the other three if they were all equal — common on a fresh repo)

**`config/bootstrap/plumbing.bicepparam`**
- `bootstrapSubscriptionId`, `location`, `githubOrg`, `moduleRepo`, `templatesRepo`, `envPlan`, `envApply`

### Idempotency

The script is safe to re-run:
- GitHub environment creation (`PUT`) is idempotent
- The ARM bootstrap deployment uses incremental mode
- GitHub variable writes overwrite the previous value
- Config file edits are in-place replacements

### After onboarding

```powershell
cd ../alz-mgmt

# Review what changed
git diff

# Adjust SUBSCRIPTION_ID_CONNECTIVITY/IDENTITY/SECURITY if they differ from Management
# Then commit and push
git add config/
git commit -m "Bootstrap: configure tenant identity and OIDC"
git push

# Open a PR → CI will validate all What-If deployments
# Once CI passes, run the CD workflow with governance-int-root=true
```

---

## cleanup.ps1 — Tenant Cleanup

Tears down all resources created by a previous bootstrap + governance deployment
so the tenant can be onboarded fresh with `onboard.ps1`.

### What it deletes

| Step | What |
|------|------|
| 1 | Governance **Deployment Stacks** at the intermediate root MG scope, in reverse dependency order. Each stack was created with `ActionOnUnmanage=DeleteAll`, so its managed resources (policy assignments, role assignments, child MGs) are deleted with it. |
| 2 | Any **management groups** still present under the intermediate root (bottom-up), then the intermediate root MG itself. |
| 3 | The **identity resource group** (contains plan + apply UAMIs and their federated identity credentials). |
| 4 | **Role assignments** for the UAMIs at the tenant root management group. |
| 5 | The custom **'Landing Zone Reader (WhatIf/Validate)'** role definition. |

It does **not** delete: the tenant root MG, any subscriptions, or GitHub environments.

### Usage

```powershell
# Preview — no changes
./scripts/cleanup.ps1 -DryRun

# Auto-loads values from ../alz-mgmt/config/platform.json
./scripts/cleanup.ps1

# Explicit values (if config repo is elsewhere)
./scripts/cleanup.ps1 `
    -IntRootMgId             'alz' `
    -TenantRootMgId          'yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy' `
    -BootstrapSubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -Location                'swedencentral'
```

The script asks you to type `YES` before making any changes.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ConfigRepoPath` | `../alz-mgmt` | Config repo path — used to load defaults from `platform.json` |
| `-IntRootMgId` | `platform.json` | Intermediate root MG name (e.g. `alz`) |
| `-TenantRootMgId` | `platform.json` | Tenant root MG GUID |
| `-BootstrapSubscriptionId` | `platform.json` | Subscription where identity RG lives |
| `-Location` | `platform.json` | Azure region — used to derive identity RG / UAMI names |
| `-IdentityRgName` | derived | Override identity RG name (default: `rg-alz-mgmt-identity-<location>-1`) |
| `-DryRun` | — | Print every action; make no changes |

### Notes on stack deletion

- Stacks are deleted in reverse dependency order: RBAC → child MGs → intermediate MGs → int-root.
- After each stack delete with `DeleteAll`, Azure removes all resources the stack owned.
- If a stack was only partially deployed, the script silently skips missing stacks.
- If the identity RG was already gone when cleanup runs, the script falls back to listing
  orphaned (Unknown) role assignments at the tenant root MG so you can remove them manually.
