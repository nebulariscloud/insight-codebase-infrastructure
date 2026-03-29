# Security Services Organization Setup Guide

## Overview

All security services are deployed organization-wide via LZA with the Audit account (021655151355) as the delegated administrator. Member accounts are automatically enrolled when created through the LZA pipeline.

## AWS GuardDuty

| Setting | Value |
|---|---|
| Delegated Admin | Audit (021655151355) |
| Scope | All member accounts, all enabled regions |
| S3 Protection | Enabled |
| EKS Protection | Enabled |
| Findings Export | S3, every 6 hours |
| Export Destination | Central-logs bucket in LogArchive (808431466229) |

### How It Works
- GuardDuty is enabled automatically in every account when the LZA pipeline runs
- New accounts added to the organization are auto-enrolled
- Findings from all accounts are aggregated in the Audit account
- Findings are exported to S3 every 6 hours for long-term retention
- GuardDuty analyzes VPC Flow Logs, CloudTrail, and DNS logs for threat detection

### Verification
Log into the Audit account → GuardDuty → Settings → confirm delegated admin status and member accounts are listed.

<!-- Insert screenshot: GuardDuty accounts page showing all member accounts enrolled -->

## AWS Security Hub

| Setting | Value |
|---|---|
| Delegated Admin | Audit (021655151355) |
| Scope | All member accounts, all regions |
| Region Aggregation | Enabled (all regions linked) |
| Standards Enabled | AWS FSBP, NIST 800-53 Rev 5, CIS AWS Foundations v3.0 |

### Enabled Standards

| Standard | Description |
|---|---|
| AWS Foundational Security Best Practices v1.0.0 | 200+ automated controls reflecting AWS security recommendations |
| NIST SP 800-53 Rev 5 | Federal security standard mapping for compliance |
| CIS AWS Foundations Benchmark v3.0.0 | Industry-recognized cloud security baseline |

### How It Works
- Security Hub aggregates findings from GuardDuty, Macie, Config, Access Analyzer, and Inspector
- All member accounts are auto-enrolled via Organizations integration
- Cross-region aggregation ensures findings from any region are visible centrally
- Standards continuously evaluate account configurations against security controls

### Verification
Log into the Audit account → Security Hub → confirm all accounts are members, all 3 standards are enabled, and region aggregation is active.

<!-- Insert screenshot: Security Hub summary showing member accounts and enabled standards -->

<!-- Insert screenshot: Security Hub linked regions showing all regions aggregated -->

## Amazon Macie

| Setting | Value |
|---|---|
| Delegated Admin | Audit (021655151355) |
| Scope | All member accounts, all enabled regions |
| Findings Frequency | Every 15 minutes |
| Policy Findings → Security Hub | Yes |
| Sensitive Data Findings → Security Hub | No (kept in Macie console to reduce noise) |

### How It Works
- Macie scans S3 buckets for sensitive data (PII, credentials, financial data)
- Policy findings (misconfigured buckets, public access) are sent to Security Hub
- Sensitive data findings remain in the Macie console for targeted review

### Verification
Log into the Audit account → Macie → confirm delegated admin status and member accounts enrolled.

<!-- Insert screenshot: Macie showing member accounts -->

## IAM Access Analyzer

| Setting | Value |
|---|---|
| Scope | Organization-wide |
| Analysis Type | External access and unused access |

### How It Works
- Continuously monitors resource policies (S3, IAM roles, KMS, Lambda, SQS, SNS) for unintended external access
- Identifies unused permissions to support least-privilege refinement

### Verification
Log into the Audit account → IAM Access Analyzer → confirm analyzer is active at organization level.

<!-- Insert screenshot: IAM Access Analyzer showing organization analyzer -->

## AWS Inspector

AWS Inspector is not currently deployed via the LZA configuration. Inspector can be enabled separately in the Audit account as delegated admin and will auto-enroll member accounts.

To enable:
1. Go to the Management account → AWS Inspector → Settings → Delegated administrator → set Audit account
2. In the Audit account → Inspector → enable EC2 scanning and ECR container scanning
3. Inspector will auto-discover EC2 instances and container images across all member accounts

Note: Inspector requires EC2 instances or ECR images to be present to generate findings. Since no workloads are deployed yet, enabling it now will show no findings until instances are launched.

## SNS Alerting

| Topic | Email | Purpose |
|---|---|---|
| SecurityHigh | insightgroup-security-high@nebulariscloud.com | Critical security findings |
| SecurityMedium | insightgroup-security-medium@nebulariscloud.com | Important security notifications |
| SecurityLow | insightgroup-security-low@nebulariscloud.com | Informational security alerts |

SNS topics are deployed in the Management account. Security Hub findings can be routed to these topics via EventBridge rules.

## AWS Config

| Setting | Value |
|---|---|
| Configuration Recorder | Enabled in all accounts |
| Delivery Channel | Enabled in all accounts |
| Rules Deployed | 27+ rules across all accounts |
| Auto-Remediation | EC2 instance profile attachment, ELB logging |
| Config Snapshots | Delivered to central-logs bucket in LogArchive |

See `05-config-cloudtrail-logging.md` for the full list of Config rules.
