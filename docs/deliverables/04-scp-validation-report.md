# SCP Validation Report

## Validation Summary

This report confirms that all Service Control Policies (SCPs), Resource Control Policies (RCPs), and Declarative Policies defined in the LZA configuration are deployed and attached to their intended targets.

The LZA configuration includes SCP revert protection (`scpRevertChangesConfig.enable: true`), meaning any manual unauthorized changes to SCPs are automatically reverted by the LZA pipeline.

## SCP Attachment Validation

| Policy | Target Type | Target | Status |
|---|---|---|---|
| Core-Guardrails-1 | OU | Infrastructure | Attached |
| Core-Guardrails-1 | OU | Security | Attached |
| Core-Guardrails-1 | OU | Workloads | Attached |
| Core-Guardrails-2 | OU | Infrastructure | Attached |
| Core-Guardrails-2 | OU | Security | Attached |
| Core-Guardrails-2 | OU | Workloads | Attached |
| Security-Guardrails-1 | Account | Audit (021655151355) | Attached |
| Security-Guardrails-1 | Account | LogArchive (808431466229) | Attached |
| Infrastructure-Guardrails-1 | Account | Network (857876979853) | Attached |
| Infrastructure-Guardrails-1 | Account | Perimeter (713939170920) | Attached |
| Infrastructure-Guardrails-1 | Account | SharedServices (547368325532) | Attached |
| Workloads-Guardrails-1 | OU | Workloads/Dev | Attached |
| Workloads-Guardrails-1 | OU | Workloads/Test | Attached |
| Workloads-Guardrails-1 | OU | Workloads/Prod | Attached |
| Sandbox-Guardrails-1 | OU | Workloads/Sandbox | Attached |
| Suspended-Guardrails | OU | Suspended | Attached |
| Quarantine | Auto-applied | New accounts on creation | Configured |

<!-- Insert screenshot: AWS Organizations → Service control policies list showing all SCPs -->

<!-- Insert screenshot: Each SCP's Targets tab showing attached OUs/accounts -->

## RCP Attachment Validation

| Policy | Target Type | Target | Status |
|---|---|---|---|
| Core-Rcp-Guardrails | OU | Infrastructure | Attached |
| Core-Rcp-Guardrails | OU | Security | Attached |
| Core-Rcp-Guardrails | OU | Workloads | Attached |

<!-- Insert screenshot: AWS Organizations → Resource control policies showing targets -->

## Declarative Policy Validation

| Policy | Target Type | Target | Status |
|---|---|---|---|
| VPC Block Public Access | OU | Security | Attached |
| VPC Block Public Access | OU | Workloads/Dev | Attached |
| VPC Block Public Access | OU | Workloads/Test | Attached |
| VPC Block Public Access | OU | Workloads/Prod | Attached |
| VPC Block Public Access | Account | Network (857876979853) | Attached |
| VPC Block Public Access | Account | SharedServices (547368325532) | Attached |

<!-- Insert screenshot: AWS Organizations → Declarative policies showing targets -->

## Re-verification Steps

To re-verify at any time:

1. Log into the Management account
2. Navigate to AWS Organizations → Policies → Service control policies
3. Click each SCP and verify the Targets tab shows the correct OUs/accounts
4. Repeat for Resource control policies and Declarative policies
