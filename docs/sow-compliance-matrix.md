# SOW Compliance Matrix — Landing Zone Deployment

## Scope of Work Coverage

| SOW Line Item | Status | Documentation |
|---|---|---|
| **Landing Zone Deployment** | | |
| Deploy/validate AWS Control Tower | DONE | `deliverables/00-project-delivery-summary.md` |
| Configure AWS SSO / identity provider | DONE | `deliverables/02-iam-cross-account-trust.md` (Identity Center section) |
| Management Account (Root) | DONE | `deliverables/06-account-structure.md` |
| Security OU — Log Archive Account | DONE | `deliverables/06-account-structure.md` |
| Security OU — Audit Account | DONE | `deliverables/06-account-structure.md` |
| Shared Services OU — Security Services Account | DONE | `deliverables/06-account-structure.md` (see "SOW Security Services Account Mapping" — Audit account serves as delegated security admin per AWS best practice) |
| Production OU — Production Account | DONE | `deliverables/06-account-structure.md` |
| Staging OU — Staging Account | DONE | `deliverables/06-account-structure.md` (mapped to Workloads/Test) |
| Non-Prod OU — Development Account | DONE | `deliverables/06-account-structure.md` |
| Non-Prod OU — QA Account | DONE | `deliverables/06-account-structure.md` |
| Non-Prod OU — UAT Account | DONE | `deliverables/06-account-structure.md` |
| Sandbox OU — Sandbox Account | DONE | `deliverables/06-account-structure.md` |
| **Governance Configuration** | | |
| Control Tower guardrails (mandatory + strongly recommended) | DONE | `deliverables/01-scp-guardrail-list.md` (Control Tower Controls section) |
| Service Control Policies (SCPs) | DONE | `deliverables/01-scp-guardrail-list.md` |
| AWS Config across all accounts | DONE | `deliverables/05-config-cloudtrail-logging.md` |
| CloudTrail across all accounts | DONE | `deliverables/05-config-cloudtrail-logging.md` |
| CloudWatch + guardrail notifications | DONE | `deliverables/00-project-delivery-summary.md` (SNS alerting section) |
| **Logging & Security** | | |
| CloudTrail logs to centralized account | DONE | `deliverables/03-logging-verification.md`, `deliverables/05-config-cloudtrail-logging.md` |
| AWS Config data to centralized account | DONE | `deliverables/03-logging-verification.md`, `deliverables/05-config-cloudtrail-logging.md` |
| AWS Config rules and detection alerts | DONE | `deliverables/05-config-cloudtrail-logging.md` (27+ rules listed) |
| Cross-account IAM roles and permissions | DONE | `deliverables/02-iam-cross-account-trust.md` |
| **Documentation & Knowledge Transfer** | | |
| Full runbook and architectural documentation | DONE | All deliverables + diagrams below |

## Deliverables Coverage

| Deliverable | Status | Location |
|---|---|---|
| **Architecture & Documentation Package** | | |
| High-level architecture diagrams | DONE | `diagrams/02-network-architecture.md`, `diagrams/03-security-architecture.md` |
| Low-level detailed architecture diagrams | DONE | `diagrams/07-ipam-allocation.md`, `diagrams/02-network-architecture.md` (VPC detail table) |
| **Landing Zone Documentation Package** | | |
| Account structure diagram (OUs, accounts, roles) | DONE | `diagrams/01-account-structure.md`, `deliverables/06-account-structure.md` |
| SCP and guardrail list with descriptions | DONE | `deliverables/01-scp-guardrail-list.md`, `diagrams/04-scp-guardrails.md` |
| AWS Config & CloudTrail centralized logging config | DONE | `deliverables/05-config-cloudtrail-logging.md`, `diagrams/06-logging-monitoring.md` |
| **Governance & Security Artifacts** | | |
| IAM cross-account trust role setup | DONE | `deliverables/02-iam-cross-account-trust.md`, `diagrams/05-iam-cross-account-trust.md` |
| Logging verification across accounts | DONE | `deliverables/03-logging-verification.md` (evidence screenshots needed) |
| SCP validation reports | DONE | `deliverables/04-scp-validation-report.md` (evidence screenshots needed) |

## Complete File Index

### Deliverables (`docs/deliverables/`)

| File | Contents |
|---|---|
| `00-project-delivery-summary.md` | Master index, environment summary, what was deployed |
| `01-scp-guardrail-list.md` | All 8 SCPs, 1 RCP, 1 Declarative Policy, 11 CT controls with descriptions |
| `02-iam-cross-account-trust.md` | All cross-account roles, policies, delegated admin assignments |
| `03-logging-verification.md` | Logging architecture, S3 buckets, lifecycle, verification steps |
| `04-scp-validation-report.md` | SCP attachment validation table, CLI verification commands |
| `05-config-cloudtrail-logging.md` | CloudTrail config, all 27 Config rules, auto-remediation |
| `06-account-structure.md` | OU hierarchy, SOW-to-LZA mapping, all accounts with IDs and emails |

### Diagrams (`docs/diagrams/`)

| File | Contents |
|---|---|
| `01-account-structure.md` | OU and account hierarchy (Mermaid) |
| `02-network-architecture.md` | Network topology, TGW routing, VPC detail table (Mermaid) |
| `03-security-architecture.md` | Security hub-and-spoke model (Mermaid) |
| `04-scp-guardrails.md` | SCP/RCP/DP to target mapping (Mermaid) |
| `05-iam-cross-account-trust.md` | Cross-account trust model (Mermaid) |
| `06-logging-monitoring.md` | Centralized logging flow (Mermaid) |
| `07-ipam-allocation.md` | IPAM pool hierarchy with CIDRs (Mermaid + table) |
| `08-compliance-standards.md` | Security Hub standards, Config rules, auto-remediation (Mermaid) |

## Remaining Evidence to Capture

1. Screenshots for logging verification (steps in `deliverables/03-logging-verification.md`)
2. Screenshots for SCP validation (steps in `deliverables/04-scp-validation-report.md`)
