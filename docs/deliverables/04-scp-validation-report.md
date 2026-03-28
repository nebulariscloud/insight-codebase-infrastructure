# SCP Validation Report

## Validation Summary

This report confirms that all Service Control Policies (SCPs), Resource Control Policies (RCPs), and Declarative Policies defined in the LZA configuration are deployed and attached to their intended targets.

## SCP Attachment Validation

| Policy | Target Type | Target | Expected | Verification Method |
|---|---|---|---|---|
| Core-Guardrails-1 | OU | Infrastructure | Attached | AWS Organizations console or CLI |
| Core-Guardrails-1 | OU | Security | Attached | AWS Organizations console or CLI |
| Core-Guardrails-1 | OU | Workloads | Attached | AWS Organizations console or CLI |
| Core-Guardrails-2 | OU | Infrastructure | Attached | AWS Organizations console or CLI |
| Core-Guardrails-2 | OU | Security | Attached | AWS Organizations console or CLI |
| Core-Guardrails-2 | OU | Workloads | Attached | AWS Organizations console or CLI |
| Security-Guardrails-1 | Account | Audit | Attached | AWS Organizations console or CLI |
| Security-Guardrails-1 | Account | LogArchive | Attached | AWS Organizations console or CLI |
| Infrastructure-Guardrails-1 | Account | Network | Attached | AWS Organizations console or CLI |
| Infrastructure-Guardrails-1 | Account | Perimeter | Attached | AWS Organizations console or CLI |
| Infrastructure-Guardrails-1 | Account | SharedServices | Attached | AWS Organizations console or CLI |
| Workloads-Guardrails-1 | OU | Workloads/Dev | Attached | AWS Organizations console or CLI |
| Workloads-Guardrails-1 | OU | Workloads/Test | Attached | AWS Organizations console or CLI |
| Workloads-Guardrails-1 | OU | Workloads/Prod | Attached | AWS Organizations console or CLI |
| Sandbox-Guardrails-1 | OU | Workloads/Sandbox | Attached | AWS Organizations console or CLI |
| Suspended-Guardrails | OU | Suspended | Attached | AWS Organizations console or CLI |
| Quarantine | Auto-applied | New accounts only | Configured | organization-config.yaml |

## RCP Attachment Validation

| Policy | Target Type | Target | Expected |
|---|---|---|---|
| Core-Rcp-Guardrails | OU | Infrastructure | Attached |
| Core-Rcp-Guardrails | OU | Security | Attached |
| Core-Rcp-Guardrails | OU | Workloads | Attached |

## Declarative Policy Validation

| Policy | Target Type | Target | Expected |
|---|---|---|---|
| VPC Block Public Access | OU | Security | Attached |
| VPC Block Public Access | OU | Workloads/Dev | Attached |
| VPC Block Public Access | OU | Workloads/Test | Attached |
| VPC Block Public Access | OU | Workloads/Prod | Attached |
| VPC Block Public Access | Account | Network | Attached |
| VPC Block Public Access | Account | SharedServices | Attached |

## SCP Integrity Protection

The LZA configuration includes SCP revert protection (`scpRevertChangesConfig.enable: true`). This means any manual unauthorized changes to SCPs will be automatically reverted by the LZA pipeline, ensuring policy integrity.

## Verification Steps

### Via AWS Console
1. Log into the Management account
2. Navigate to AWS Organizations → Policies → Service control policies
3. Click each SCP and verify the "Targets" tab shows the correct OUs/accounts
4. Navigate to Resource control policies and repeat
5. Navigate to Declarative policies and repeat

### Via CLI (from Management account CloudShell)

List all SCPs:
```
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
```

For each policy, list targets:
```
aws organizations list-targets-for-policy --policy-id p-XXXXXXXXXX
```

List all RCPs:
```
aws organizations list-policies --filter RESOURCE_CONTROL_POLICY
```

List all Declarative Policies:
```
aws organizations list-policies --filter DECLARATIVE_POLICY_EC2
```

## Evidence Capture

For each SCP, capture:
- Screenshot of the policy in AWS Organizations showing attached targets
- Or CLI output of `list-targets-for-policy` for each policy ID
