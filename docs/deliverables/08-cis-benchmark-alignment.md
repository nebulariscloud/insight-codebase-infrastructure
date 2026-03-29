# CIS AWS Foundations Benchmark Alignment Report

## Overview

The LZA deployment enables the CIS AWS Foundations Benchmark v3.0.0 standard in AWS Security Hub across all accounts in the organization. Security Hub continuously evaluates account configurations against CIS controls and generates findings for any non-compliant resources.

## CIS Standard Status

| Setting | Value |
|---|---|
| Standard | CIS AWS Foundations Benchmark v3.0.0 |
| Deployed To | All accounts (Root OU) |
| Evaluation | Continuous, automated |
| Findings Aggregation | Audit account (021655151355) with cross-region aggregation |

## CIS Control Coverage by LZA Configuration

### Identity and Access Management

| CIS Control Area | LZA Implementation |
|---|---|
| Root account usage | Blocked by SCP (Core-Guardrails-2) |
| MFA enforcement | IAM password policy configured (14 char min, complexity required) |
| IAM user creation | Blocked by SCP — federated access via Identity Center enforced |
| Access key rotation | Monitored by Security Hub CIS standard |
| IAM policies | No inline policies (enforced by Control Tower control + Config rule) |
| IAM Access Analyzer | Enabled organization-wide |

### Logging

| CIS Control Area | LZA Implementation |
|---|---|
| CloudTrail enabled | Organization trail via Control Tower |
| CloudTrail log validation | Enabled by Control Tower |
| CloudTrail S3 data events | Enabled via Control Tower control |
| Config enabled | Configuration recorder + delivery channel in all accounts |
| VPC Flow Logs | Enabled on all VPCs, sent to CloudWatch + S3 |
| CloudWatch Log encryption | Enforced via Control Tower control |

### Monitoring

| CIS Control Area | LZA Implementation |
|---|---|
| Security Hub enabled | Enabled in all accounts (enforced by Control Tower control) |
| GuardDuty enabled | Enabled in all accounts with S3 + EKS protection |
| GuardDuty findings monitoring | Non-archived findings Config rule (1d high, 7d medium, 30d low) |
| SNS alerting | SecurityHigh/Medium/Low topics configured |
| Budget monitoring | $2,000/mo budget with 50/75/80/90/100% alerts |

### Networking

| CIS Control Area | LZA Implementation |
|---|---|
| Default VPCs removed | Deleted in all accounts |
| Security groups | No unrestricted inbound access (enforced by SCP) |
| VPC public access | Blocked by Declarative Policy on Security, Dev, Test, Prod OUs + Network, SharedServices accounts |
| Internet gateway controls | Authorized VPC only (Control Tower control + Config rule) |
| No unrestricted route to IGW | Enforced by Control Tower control |

### Data Protection

| CIS Control Area | LZA Implementation |
|---|---|
| EBS encryption | Default encryption enabled in all accounts |
| S3 public access block | Enabled in all accounts |
| S3 bucket encryption | Enforced by default |
| Backup encryption | Recovery point encryption checked by Config rule |
| KMS key protection | Protected by SCP (Core-Guardrails-1) |
| Secrets Manager CMK | Monitored by Config rule |

## How to View CIS Compliance Score

1. Log into the Audit account
2. Navigate to Security Hub → Security standards → CIS AWS Foundations Benchmark v3.0.0
3. View the overall compliance score and individual control statuses
4. Filter by account, region, or control status to drill into specific findings

<!-- Insert screenshot: Security Hub CIS benchmark showing compliance score -->

<!-- Insert screenshot: Security Hub CIS controls list showing pass/fail status -->

## Additional Standards Enabled

| Standard | Purpose |
|---|---|
| AWS Foundational Security Best Practices v1.0.0 | AWS-maintained, continuously updated security controls |
| NIST SP 800-53 Rev 5 | Federal compliance framework mapping |

These standards provide overlapping coverage — controls missed by one framework are typically caught by another.
