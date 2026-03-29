# SOW 2 Compliance Matrix — Security & Compliance Services

## Scope of Work Coverage

| SOW Line Item | Status | Documentation |
|---|---|---|
| **AWS Control Tower Integration** | | |
| Provision/validate Security OU and Security account | DONE | `deliverables/06-account-structure.md` (Audit account = Security account) |
| Cross-account IAM roles for centralized monitoring | DONE | `deliverables/02-iam-cross-account-trust.md` |
| SCPs to enforce security boundaries | DONE | `deliverables/01-scp-guardrail-list.md`, `deliverables/04-scp-validation-report.md` |
| Register Security account as delegated admin | DONE | `deliverables/07-security-services-setup-guide.md` |
| **Security Service Deployment** | | |
| GuardDuty enabled in Security account | DONE | `deliverables/07-security-services-setup-guide.md` |
| GuardDuty delegated admin + all member accounts | DONE | `deliverables/07-security-services-setup-guide.md` |
| GuardDuty custom threat detection (S3, DNS) | DONE | S3 Protection enabled, DNS logs analyzed by default |
| GuardDuty → EventBridge + CloudWatch integration | DONE | Findings export to S3 every 6hrs, SNS alerting configured |
| Security Hub with AWS FSBP | DONE | `deliverables/07-security-services-setup-guide.md` |
| Security Hub all member accounts connected | DONE | `deliverables/07-security-services-setup-guide.md` |
| Security Hub finding aggregation | DONE | Cross-region aggregation enabled, all regions linked |
| AWS Inspector across all accounts | PARTIAL | Not deployed via LZA. Can be enabled manually. See `deliverables/07-security-services-setup-guide.md` for steps. |
| **Logging & Visibility** | | |
| Centralized AWS Config rules | DONE | `deliverables/05-config-cloudtrail-logging.md` (27+ rules) |
| Compliance rules and remediation alerts | DONE | 2 auto-remediation rules (EC2 instance profile, ELB logging) |
| **Monitoring & Alerts** | | |
| SNS alerting | DONE | SecurityHigh/Medium/Low topics, Budget alerts |
| CloudWatch dashboards | NOT DEPLOYED | LZA does not deploy custom dashboards by default. Can be added. |
| Slack/webhook integration | NOT DEPLOYED | Optional per SOW. Can be configured via EventBridge + Lambda/Chatbot. |
| Budget alerts and anomaly detection | DONE | $2,000/mo budget with 5 threshold alerts |
| **Governance & Compliance** | | |
| Map controls to CIS AWS Foundations | DONE | `deliverables/08-cis-benchmark-alignment.md` |
| Compliance dashboard in Security Hub | DONE | CIS v3.0, FSBP, NIST 800-53 all enabled |
| Document IAM, logging, monitoring posture | DONE | `deliverables/02-iam-cross-account-trust.md`, `deliverables/03-logging-verification.md` |
| **Documentation & Knowledge Transfer** | | |
| Architecture diagrams | DONE | `diagrams/01-08` (8 Mermaid diagrams) |
| Service configuration documentation | DONE | `deliverables/07-security-services-setup-guide.md` |
| Runbooks for monitoring, alert triage, reporting | SEE BELOW | |

## Deliverables Coverage

| Deliverable | Status | Location |
|---|---|---|
| Centralized security operations architecture | DONE | `diagrams/03-security-architecture.md` |
| IAM roles, SCP policies, cross-account trust documentation | DONE | `deliverables/02-iam-cross-account-trust.md`, `deliverables/01-scp-guardrail-list.md` |
| Security Hub and GuardDuty org setup guide | DONE | `deliverables/07-security-services-setup-guide.md` |
| Logging and alerting configuration documentation | DONE | `deliverables/03-logging-verification.md`, `deliverables/05-config-cloudtrail-logging.md` |
| CIS benchmark alignment report | DONE | `deliverables/08-cis-benchmark-alignment.md` |
| Security policy summary and SCP document | DONE | `deliverables/01-scp-guardrail-list.md`, `deliverables/04-scp-validation-report.md` |

## Items to Address

1. **AWS Inspector**: Not deployed via LZA. Enable manually in Audit account as delegated admin. Steps documented in `deliverables/07-security-services-setup-guide.md`. No findings will appear until EC2 instances or ECR images exist.

2. **CloudWatch Dashboards**: Not deployed by default. Optional — can be created manually or via CloudFormation if the client wants visual dashboards.

3. **Slack/Webhook Integration**: Optional per SOW. Can be configured using Amazon EventBridge rules → AWS Chatbot (for Slack) or Lambda (for webhooks).

4. **Runbooks**: The deliverable documents serve as operational runbooks. Each document includes verification steps that can be repeated for ongoing monitoring.
