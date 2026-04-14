# OIDC Subject Contract (DO NOT BREAK)

This repository participates in GitHub OIDC federated identity credentials where the **subject**
string is matched exactly.

If you change any of the items below, Azure login via OIDC will fail until federated credentials
are recreated.

## Locked GitHub Environments (MUST NOT RENAME)
These environment names are part of the OIDC subject:

- alz-mgmt-plan
- alz-mgmt-apply

## Subject format (for reference)
```
repo:<ORG>/<MODULE_REPO>:environment:<ENV>
```

Example:
```
repo:ExjobbOA/alz-mgmt-oskar:environment:alz-mgmt-plan
repo:ExjobbOA/alz-mgmt-oskar:environment:alz-mgmt-apply
```

## Why not job_workflow_ref?

The engine repo is consumed via semver tags (`v1.0.0`, `v2.0.0`, etc.) so each config repo can
upgrade independently. `job_workflow_ref` embeds the exact git ref of the calling workflow, which
would require a new federated credential every time the engine tag changes — that doesn't scale.

Environment-only matching is tag-agnostic. GitHub environment protection rules already control
who can trigger deployments, so security is maintained without the ref in the subject.

## What is no longer locked

- **Workflow file paths** — `.github/workflows/ci-template.yaml` and `cd-template.yaml` can be
  renamed freely; they are not part of the subject.
- **Branch/tag refs** — any engine tag or branch can be referenced from a config repo without
  creating new federated credentials.

## Migrating existing tenants

Tenants bootstrapped before this change have FICs with the old `job_workflow_ref` subject format.
To migrate:

1. Reset the GitHub OIDC subject customization on the config repo:
   ```bash
   gh api --method PUT "repos/ORG/CONFIG_REPO/actions/oidc/customization/sub" \
     --input - <<< '{"use_default":true}'
   ```

2. Re-run bootstrap to replace the old FICs (`ci-plan`, `cd-plan`, `cd-apply`) with the new
   ones (`github-plan`, `github-apply`):
   ```powershell
   ./scripts/onboard.ps1 -ConfigRepoPath ../CONFIG_REPO ...
   ```

3. Delete the old FICs once the new ones are confirmed working:
   ```bash
   az identity federated-credential delete --name ci-plan  --identity-name <plan-uami>  --resource-group <rg>
   az identity federated-credential delete --name cd-plan  --identity-name <plan-uami>  --resource-group <rg>
   az identity federated-credential delete --name cd-apply --identity-name <apply-uami> --resource-group <rg>
   ```
