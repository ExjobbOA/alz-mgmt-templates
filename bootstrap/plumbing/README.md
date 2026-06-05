# Bootstrap – OIDC Identity Plumbing

This bootstrap deploys:

- Resource Group for identities
- User Assigned Managed Identity (plan)
- User Assigned Managed Identity (apply)
- **2** Federated Identity Credentials (GitHub OIDC): `github-plan` and `github-apply`
- Role assignments on Management Group scope

This step must be executed once per tenant before CI/CD can authenticate using OIDC.

See `bootstrap/subjects/subject-contract.md` for the authoritative OIDC subject model.
The FIC subjects use **environment-only** format (`repo:ORG/REPO:environment:ENV`) —
workflow file paths and branch refs are NOT part of the subject and do not need to match
specific values.

---

# Prerequisites

You must have:

- Owner or equivalent rights on the target Management Group
- Permission to create:
  - Resource Groups
  - User Assigned Managed Identities
  - Role Assignments at MG scope
- Bicep CLI installed (`az bicep install`)

---

# Option A — Automated (recommended)

Run `scripts/onboard.ps1` from the templates repo. It deploys the bootstrap Bicep,
creates the GitHub environments, and writes all required variables — one command.

See [`scripts/README.md`](../../scripts/README.md) for prerequisites and usage.

---

# Option B — Manual deploy

Run from the **engine repo** root (where `bootstrap/plumbing/main.bicep` lives):

```bash
az login
az account set --subscription <BOOTSTRAP_SUBSCRIPTION_ID>

az deployment mg create \
  --name alz-bootstrap \
  --management-group-id <TENANT_ROOT_MG_GUID> \
  --location swedencentral \
  --template-file bootstrap/plumbing/main.bicep \
  --parameters @config/bootstrap/plumbing.bicepparam
```

> The `--parameters` file is `config/bootstrap/plumbing.bicepparam` in the **tenant config
> repo** (not the engine repo). Update it with your subscription ID and org/repo values
> before running. See the header comment in that file for the full list of parameters.
