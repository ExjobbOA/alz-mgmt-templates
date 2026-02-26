# scripts/

## onboard.ps1 — Tenant Onboarding

Bootstraps a new Azure Landing Zone tenant end-to-end in a single command.

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

### Prerequisites

| Tool | Purpose |
|------|---------|
| PowerShell 7+ (`pwsh`) | Script runtime |
| Azure CLI (`az`) | Authenticated via `az login`; needs Owner (or equivalent) on the root management group |
| GitHub CLI (`gh`) | Authenticated via `gh auth login`; needs admin access to the config repo |
| Git | Used to auto-detect org/repo names from remotes |

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
