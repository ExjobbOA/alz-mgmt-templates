# Logbook: Thesis Project - ALZ Bicep & IaC

### Feb 1–9: Project Initiation and Setup

* **Planning**: Established the purpose, research questions, and methodology for the thesis.
* **Environment**: Configured the local machine with Azure CLI, Git, VS Code, and PowerShell 7.
* **Bootstrap**: Utilized the `Deploy-Accelerator` to generate the GitHub organization and the initial repositories.
* **Configuration**: Defined `swedencentral` as the primary region and set `6f051987-3995-4c82-abb3-90ba101a0ab4` as the target platform subscription.

### Feb 10: Initial Deployment & Cleanup

* **Incident**: Accidentally triggered a CD flow that deployed resources before the configuration was fully finalized.
* **Recovery**: Manually cleared Deployment Stacks, moved the subscription back, and deleted incorrectly created Management Groups.
* **CI/CD Hardening**: Modified `cd.yaml` to disable automatic execution on push to main and set all deployment steps to a default value of `false`.

### Feb 11–17: Major Architectural Refactoring

* **Repository Restructuring**: Refactored the entire codebase into a two-repo architecture to separate logic from configuration:
* **Engine Repo**: Centralized Bicep modules and generic workflow logic.
* **Tenant Repo**: Contains environment-specific configurations, parameters, and tenant-unique deployment triggers.


* **Paradox Solution**: Addressed the "Cold Start Paradox" where pipelines failed against empty tenants. Updated `bicep-deploy` logic to verify the existence of the `alz` Management Group before attempting `What-If` operations.
* **OIDC & IAM**: Configured Federated Identity Credentials (FIC) to allow GitHub to authenticate via OIDC, eliminating the need for client secrets.

### Feb 18–19: Bootstrap Implementation & Workflow Optimization

* **Cloud Shell Bootstrap**: Implemented a Bicep-based bootstrap solution designed to be run manually via Cloud Shell at the subscription scope. This ensures a self-sovereign setup independent of external Terraform modules.
* **Bicep Guardrails**: Introduced `@batchSize(1)` on module loops for role assignments to mitigate transient errors caused by Entra ID propagation delays (eventual consistency).
* **Deterministic Flow**: Split the deployment phase into several separate jobs (Governance, Logging, Connectivity) with explicit `needs` dependencies to prevent race conditions.

### Feb 20: Connectivity Troubleshooting & Reversion to Monolith CD

* **Observation**: The pipeline execution failed during the Platform Connectivity stage. The process terminated without providing a specific error code or descriptive log message, and the subscription remained in its original Management Group.
* **Troubleshooting**: Investigated the **Azure Activity Log** and extracted a JSON entry revealing a `BadRequest` hidden behind the asynchronous operation.
* **Root Cause**: An IAM Condition attached to the `apply` identity's *User Access Administrator* role restricted the management of `Owner` and `UAA` roles, which was required for the subscription move.
* **Resolution**: Manually adjusted the IAM Condition to permit the operations required for subscription movement.
* **CD Strategy**: Due to the difficulty of debugging silent failures in a split-job architecture, decided to revert to a **monolithic CD pipeline** to ensure better visibility and state consistency during the current phase.
