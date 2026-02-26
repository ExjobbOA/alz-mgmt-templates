# alz-mgmt-templates — Azure Landing Zone Engine/Templates Repo

> Maintainers: Oskar Granlöf & Alen Fazlagic  
> GitHub Org: `ExjobbOA`  
> This is the **engine/templates repo** in a dual-repo ALZ Bicep architecture.

## Project Status: Active Development

This platform is a work-in-progress thesis project. The high-level architecture (dual-repo split, AVM modules, ALZ policy library, Deployment Stacks) is settled. The implementation details — template structure, parameter flow, workflow logic — are actively evolving.

**Planned changes include:**
- A centralized parameters approach in the tenant repo that populates all `.bicepparam` files, which may change how templates receive their inputs
- Ongoing refactoring of workflow and action logic

**When working in this codebase:** The architectural patterns below are stable, but always read the actual files for current details. If this doc contradicts the code, the code wins. `records.md` in this repo is the living decision log — check it for the latest context on what was tried, what broke, and why.

## Architecture Overview

This platform uses a **two-repo split**:

| Repo | Role | Contains |
|------|------|----------|
| **alz-mgmt** | Tenant configuration | `.bicepparam` files, `platform.json`, CI/CD trigger workflows |
| **alz-mgmt-templates** (this repo) | Engine/templates | Bicep modules, reusable workflows, composite actions, ALZ policy library |

At CI/CD time, this repo is checked out to `./platform/` inside the tenant repo workspace. Tenant `.bicepparam` files reference templates here via `../../platform/templates/...`.

## Repo Structure

```
alz-mgmt-templates/
├── records.md                                # Architecture Decision Records / logbook
├── scripts/
│   ├── onboard.ps1                           # One-command tenant onboarding (az + gh CLI)
│   ├── cleanup.ps1                           # Tears down a tenant back to blank slate (Az PS module)
│   └── README.md                             # Prerequisites, auth, and usage instructions
├── bootstrap/
│   ├── plumbing/
│   │   ├── main.bicep                        # MG-scoped bootstrap: creates UAMI + OIDC FIC + RBAC
│   │   ├── main.json                         # ARM compiled version — keep in sync with Bicep source
│   │   ├── modules/
│   │   │   ├── identity-oidc.bicep           # Sub-scoped: RG + UAMI + federated credentials
│   │   │   └── uami-oidc.bicep              # Individual UAMI + FIC pairs
│   │   └── README.md
│   └── subjects/
│       └── subject-contract.md               # OIDC subject claim format documentation
├── templates/
│   ├── core/
│   │   ├── alzCoreType.bicep                 # Shared user-defined type for MG config objects
│   │   ├── governance/
│   │   │   ├── lib/alz/                      # ALZ policy library (JSON files)
│   │   │   │   ├── *.alz_policy_definition.json
│   │   │   │   ├── *.alz_policy_set_definition.json
│   │   │   │   ├── *.alz_policy_assignment.json
│   │   │   │   ├── *.alz_role_definition.json
│   │   │   │   ├── landingzones/             # LZ-scoped policy assignments
│   │   │   │   │   ├── corp/                 # Corp LZ-specific assignments
│   │   │   │   │   └── *.alz_policy_assignment.json
│   │   │   │   ├── platform/                 # Platform-scoped policy assignments
│   │   │   │   │   ├── connectivity/
│   │   │   │   │   ├── identity/
│   │   │   │   │   └── *.alz_policy_assignment.json
│   │   │   │   ├── decommissioned/
│   │   │   │   └── sandbox/
│   │   │   ├── mgmt-groups/                  # Bicep templates per MG scope
│   │   │   │   ├── int-root/
│   │   │   │   │   └── main.bicep            # THE core module — deploys intermediate root + all policies
│   │   │   │   ├── landingzones/
│   │   │   │   │   ├── main.bicep
│   │   │   │   │   ├── main-rbac.bicep
│   │   │   │   │   ├── landingzones-corp/main.bicep
│   │   │   │   │   └── landingzones-online/main.bicep
│   │   │   │   ├── platform/
│   │   │   │   │   ├── main.bicep / main-rbac.bicep
│   │   │   │   │   ├── platform-connectivity/
│   │   │   │   │   ├── platform-identity/
│   │   │   │   │   ├── platform-management/
│   │   │   │   │   └── platform-security/
│   │   │   │   ├── sandbox/main.bicep
│   │   │   │   └── decommissioned/main.bicep
│   │   │   └── tooling/
│   │   │       ├── Update-AlzLibraryReferences.ps1  # Script to update ALZ lib from upstream
│   │   │       └── alz_library_metadata.json
│   │   └── logging/
│   │       └── main.bicep                    # LAW, Automation Account, AMA, DCRs
│   └── networking/
│       ├── hubnetworking/main.bicep          # Hub & spoke VNet topology
│       └── virtualwan/main.bicep             # Virtual WAN topology
└── .github/
    ├── workflows/
    │   ├── ci-template.yaml                  # Reusable: Bicep lint + What-If validation
    │   └── cd-template.yaml                  # Reusable: Deployment Stacks with selective steps
    └── actions/
        ├── bicep-deploy/action.yaml          # Composite: What-If or Deployment Stack deploy
        ├── bicep-first-deployment-check/action.yaml  # Checks if ALZ MG exists (cold-start)
        ├── bicep-installer/action.yaml       # Installs Bicep CLI + Az module
        └── bicep-variables/action.yaml       # Parses platform.json → env vars
```

## Key Bicep Patterns

### Shared Type System
`templates/core/alzCoreType.bicep` exports the `alzCoreType` user-defined type. All MG templates import this:
```bicep
import { alzCoreType as alzCoreType } from '../../../alzCoreType.bicep'
```
This type defines the shape of MG config objects including: MG name, display name, parent ID, policy/RBAC customizations, consistency counters, and subscription placement.

### Policy Library Architecture
The `lib/alz/` directory contains the full ALZ policy library as JSON files. These are loaded via `loadJsonContent()` in the MG templates:
```bicep
var alzPolicyDefsJson = [
  loadJsonContent('../../lib/alz/Deny-Storage-minTLS.alz_policy_definition.json')
  // ... hundreds more
]
```

Policy files follow naming conventions:
- `*.alz_policy_definition.json` — custom policy definitions
- `*.alz_policy_set_definition.json` — policy initiatives
- `*.alz_policy_assignment.json` — assignments (scoped by directory: root, landingzones/, platform/, etc.)
- `*.alz_role_definition.json` — custom RBAC roles

### Module Sources
All Azure resources use **AVM (Azure Verified Modules)** from the public Bicep registry:
- `br/public:avm/ptn/alz/empty:0.3.5` — the ALZ "empty" pattern for MG setup
- `br/public:avm/ptn/alz/ama:0.1.1` — Azure Monitoring Agent resources
- `br/public:avm/res/resources/resource-group:0.4.3`
- `br/public:avm/res/automation/automation-account:0.17.1`
- `br/public:avm/res/operational-insights/workspace:0.14.2`
- `br/public:avm/res/network/virtual-network:0.7.2`

### Deployment Scope Conventions
- **Governance templates**: `targetScope = 'managementGroup'`
- **Logging template**: `targetScope = 'subscription'`
- **Networking templates**: `targetScope = 'subscription'`

### Policy Assignment Override Mechanism
The `int-root/main.bicep` has a sophisticated override system:
1. Loads ALZ policy assignments from JSON
2. Accepts `parPolicyAssignmentParameterOverrides` from the tenant repo
3. Uses `union()` to merge tenant-specific values (LAW IDs, emails, etc.) into assignments
4. Handles `managementGroupFinalName` replacement in policy definition IDs
5. Deduplicates assignments when customer adds custom ones with the same name

### RBAC Role Definitions
Built-in role GUIDs are hardcoded as variables in each template. Policy assignments that need managed identity get their role definitions mapped via `alzPolicyAssignmentRoleDefinitions`.

## GitHub Actions Architecture

### Reusable Workflows (called by tenant repo)
- `ci-template.yaml`: Bicep build/lint → What-If for all scopes
- `cd-template.yaml`: Selective deployment via boolean inputs per scope

### Composite Actions
- **`bicep-deploy`**: The core action. Handles What-If mode and Deployment Stack mode with:
  - Target MG existence checking (avoids What-If on non-existent MGs)
  - First-deployment cold-start detection
  - Deployment name generation with prefix/override support
  - Auto-cleanup of deployment history before each run
  - Retry loop (10 attempts, incremental backoff)
  - Deny settings and action-on-unmanage for stacks
- **`bicep-variables`**: Parses `platform.json` and exports values as `GITHUB_ENV` variables
- **`bicep-first-deployment-check`**: Checks if the intermediate root MG exists
- **`bicep-installer`**: Installs Bicep CLI and updates the Az PowerShell module

## Bootstrap Process

The bootstrap creates the GitHub OIDC identity foundation for a new tenant. Use `scripts/onboard.ps1` — it wraps the full flow:

```powershell
./scripts/onboard.ps1 `
    -ConfigRepoPath          '../<tenant-config-repo>' `
    -ModuleRepo              '<tenant-config-repo-name>' `
    -BootstrapSubscriptionId '<subscription-guid>' `
    -ManagementGroupId       '<tenant-root-mg-guid>' `
    -Location                'swedencentral'
```

What `onboard.ps1` does:
1. Creates GitHub environments (`alz-mgmt-plan`, `alz-mgmt-apply`) via `gh api`
2. Runs `bootstrap/plumbing/main.json` as an `az deployment mg create` at tenant root MG scope
3. Captures `planClientId`, `applyClientId`, `identityResourceGroup` from deployment outputs
4. Writes `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as GitHub env variables per environment
5. Updates `config/platform.json` and `config/bootstrap/plumbing.bicepparam` in the tenant config repo

**Auth requirements for `onboard.ps1`:** `az login --tenant <id>` (MFA may require the `--tenant` flag to force browser flow) + `gh auth login`.

**`cleanup.ps1`** tears a tenant back to a blank slate (deletes Deployment Stacks, MGs, identity RG, role assignments). Uses the `Az` PowerShell module only — does NOT need `az` CLI or `gh`. Run `Connect-AzAccount` + `Set-AzContext -Subscription <id>` before running.

**Important:** `onboard.ps1` and `cleanup.ps1` require separate auth flows. `az login` and `Connect-AzAccount` are independent — logging into one does not log into the other.

### Bootstrap template: main.json vs main.bicep

`onboard.ps1` deploys `bootstrap/plumbing/main.json` (the compiled ARM JSON), not the `.bicep` source. If you modify any `.bicep` files under `bootstrap/plumbing/`, you must recompile and update `main.json` to pick up the changes. The Bicep compiler does not always preserve explicit `dependsOn` chains in child resources correctly — verify the compiled JSON after recompiling.

## Bicep Conventions

- Use `@description()` decorators on all parameters
- Use `@export()` for shared types
- Parameter naming: `par` prefix (e.g., `parLocations`, `parEnableTelemetry`)
- Variable naming: `var` prefix for computed values
- Module naming: `mod` prefix for module calls
- Resource naming: `res` prefix for resource declarations
- Lock type: custom `lockType` UDT with `kind`, `name`, `notes`
- Telemetry: `parEnableTelemetry` flag on all modules (defaults to `true`)
- Locations array: `parLocations` with primary at index 0, secondary at index 1

## Reference Sources

When writing or modifying Bicep code, always verify against official sources:

- **AVM Module Index**: https://aka.ms/avm/moduleindex — check here for latest module versions and available parameters before using any `br/public:avm/...` module
- **AVM Bicep Modules (GitHub)**: https://github.com/Azure/bicep-registry-modules/tree/main/avm — source code and examples for all AVM modules
- **Bicep Language Docs**: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/
- **ALZ Bicep Guidance**: https://aka.ms/alz/bicep
- **Azure Policy Built-in Definitions**: https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies
- **Deployment Stacks**: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks
- **ALZ Policy Library (upstream)**: https://github.com/Azure/Azure-Landing-Zones-Library

When referencing an AVM module, always check the GitHub source for:
1. Current latest version tag
2. Available parameters and their types
3. Example usage in the module's `tests/` or `examples/` folder

Do not assume module versions or parameter names from memory — they change frequently. Always verify.

## Common Tasks

### Adding a new policy definition
1. Add the JSON file to `templates/core/governance/lib/alz/`
2. Add a `loadJsonContent()` entry in the relevant MG template's `alzPolicyDefsJson` array

### Adding a new management group template
1. Create `templates/core/governance/mgmt-groups/<parent>/<child>/main.bicep`
2. Import `alzCoreType` and follow the existing pattern
3. Add What-If step to `ci-template.yaml`
4. Add deploy step to `cd-template.yaml`

### Updating the ALZ policy library
Run `tooling/Update-AlzLibraryReferences.ps1` which references `alz_library_metadata.json` to sync from the upstream ALZ library.

## Known Issues & Workarounds

1. **DDoS ghost reference**: Azure Policy with `Modify` effect injecting deleted DDoS plan IDs. Solution: disable policy enforcement or ensure DDoS plan exists. See `records.md` for full story.
2. **BCP183/BCP182**: Bicep doesn't allow function calls or output refs in module `params` outside object literals. Workaround: object spread (`...`) or dual-module pattern.
3. **Deployment cancellation trap**: The retry logic treats cancellation as failure. Must kill the GitHub Runner to truly stop.
4. **ARM eventual consistency**: Entra ID propagation causes transient RBAC errors. Use `waitForConsistencyCounter*` params and `@batchSize(1)`.
5. **Concurrent Federated Identity Credential writes**: Azure rejects parallel writes of multiple FICs to the same UAMI (`ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity`). The Bicep compiler may not preserve `dependsOn` chains for child resources in the compiled `main.json`. Fix: verify the compiled JSON has sequential dependencies (`cd-plan` → `ci-plan`, `cd-apply` → `cd-plan`) and patch manually if needed. See `records.md` Feb 26 entry.
6. **PowerShell quote-stripping with `az`**: Passing a JSON string directly to `az --parameters` on Windows causes PowerShell to strip quotes, producing `{key:{value:...}}` which `az` cannot parse. Fix: write JSON to a temp file and pass `@<path>` instead of an inline string.
