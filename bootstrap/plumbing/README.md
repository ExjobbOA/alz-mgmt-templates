# Bootstrap – OIDC Identity Plumbing

This bootstrap deploys:

- Resource Group for identities
- User Assigned Managed Identity (plan)
- User Assigned Managed Identity (apply)
- 3 Federated Identity Credentials (GitHub OIDC)
- Role assignments on Management Group scope

This step must be executed once per tenant before CI/CD can authenticate using OIDC.

---

## ⚠️ Important

The following must NOT be changed without recreating federated credentials:

- Workflow paths:
  - `.github/workflows/ci-template.yaml`
  - `.github/workflows/cd-template.yaml`

- GitHub Environments:
  - `alz-mgmt-plan`
  - `alz-mgmt-apply`

- Branch reference used in subject (default):
  - `refs/heads/main`

See `bootstrap/subjects/subject-contract.md` for full details.

---

# Prerequisites

You must have:

- Owner or equivalent rights on the target Management Group
- Permission to create:
  - Resource Groups
  - User Assigned Managed Identities
  - Role Assignments at MG scope

---

# Step 0 – Execute Bootstrap

Run from repository root:

```bash
az login
az account set --subscription <BOOTSTRAP_SUBSCRIPTION_ID>

az deployment mg create \
  --name alz-bootstrap \
  --management-group-id <TARGET_MG_ID> \
  --location swedencentral \
  --template-file bootstrap/plumbing/main.bicep \
  --parameters @config/tenants/<TENANT>/bootstrap/plumbing.bicepparam
