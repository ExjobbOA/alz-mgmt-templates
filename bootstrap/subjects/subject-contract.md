# OIDC Subject Contract (DO NOT BREAK)

This repository participates in GitHub OIDC federated identity credentials where the **subject**
string is matched exactly.

If you change any of the items below, Azure login via OIDC will fail until federated credentials
are recreated.

## Locked workflow paths (MUST NOT CHANGE)
These files must keep the same path and filename:

- .github/workflows/ci-template.yaml
- .github/workflows/cd-template.yaml

## Locked GitHub Environments (MUST NOT RENAME)
These environment names are part of the OIDC subject (Terraform/Accelerator-compatible format):

- alz-mgmt-plan
- alz-mgmt-apply

## Locked branch reference used in subject
Federated credentials are created for this workflow ref:

- refs/heads/main

If you need to change branch/ref strategy (tags, releases, other branches):
1) Add NEW federated credentials first (parallel)
2) Migrate callers
3) Remove old credentials last

## Subject format (for reference)
repo:<ORG>/<MODULE_REPO>:environment:<ENV>:job_workflow_ref:<ORG>/<TEMPLATES_REPO>/<WORKFLOW_PATH>@<REF>

Example:
repo:ExjobbOA/alz-mgmt:environment:alz-mgmt-plan:job_workflow_ref:ExjobbOA/alz-mgmt-templates/.github/workflows/ci-template.yaml@refs/heads/main
