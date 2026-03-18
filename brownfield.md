# Iteration 2: Brownfield Integration

## Objective
Demonstrate that the ALZ platform can assess and safely integrate 
existing ClickOps-built landing zones into GitOps governance 
without disrupting workloads.

## Approach

### Phase 1: Reference Analysis
- Export state from decommissioned tenant (read-only)
- Document structural characteristics: management groups, policies, 
  subscriptions, RBAC
- Identify brownfield patterns (drift, naming conventions, policy 
  overlaps, orphaned resources)

### Phase 2: Test Environment Replication
- Create a controlled test tenant replicating brownfield 
  characteristics
- Deploy platform stacks in audit-only mode
- Baseline compliance assessment

### Phase 3: Safe Migration Workflow
- Move test subscription into platform hierarchy
- Observe policy compliance evaluation
- Categorize findings: compliant (green), out-of-scope (yellow), 
  conflicting (red)
- Document decision points and remediation steps

### Phase 4: Iteration & Documentation
- Repeat workflow with multiple test subscriptions
- Build playbook of common conflict patterns and resolutions
- Document safe sequence and guard rails

## Deliverables
1. State export/comparison tooling
2. Test environment documentation
3. Migration workflow playbook
4. Evidence: compliance reports from test runs
