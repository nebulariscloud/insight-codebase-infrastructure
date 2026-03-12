# Standard Operating Procedure: Workload Health KPI Development Guide
# Defining, Monitoring, and Analyzing Customer Workload Health

| Field | Value |
|---|---|
| Document ID | SOP-002 |
| Version | 1.0 |
| Classification | Internal — Partner Confidential |
| Effective Date | [DATE] |
| Last Reviewed | [DATE] |
| Owner | Cloud Operations Team |
| Approved By | [NAME], Director of Cloud Engineering |

---

## 1. Purpose

This document provides standardized guidance for developing, collecting, and analyzing workload health Key Performance Indicators (KPIs) for customer environments deployed on AWS. It defines the methodology for establishing metrics, configuring logging, and setting alerting thresholds that enable proactive detection and resolution of operational events.

This procedure satisfies the requirements defined in OPE-001 of the AWS Partner Network Service Delivery Program.

---

## 2. Scope

This guide applies to all customer engagements where the partner deploys, migrates, or manages workloads on AWS. It covers:

- Infrastructure-level health metrics (compute, network, storage)
- Security posture metrics (compliance, threat detection)
- Application-level logging and error capture
- Alerting thresholds and notification workflows

---

## 3. KPI Framework Overview

Every customer workload health monitoring implementation consists of three pillars:

1. **Metric Definition and Collection** — What to measure and how to collect it
2. **Application Logging** — Capturing errors and operational data for troubleshooting
3. **Alerting Thresholds** — When to notify and who to notify

---

## 4. Pillar 1: Metric Definition and Collection

### 4.1 Infrastructure Metrics

The following metrics are collected by default for all customer environments using Amazon CloudWatch:

| Component | Metric | Source | Collection Interval |
|---|---|---|---|
| EC2 Instances | CPUUtilization, NetworkIn/Out, DiskReadOps, StatusCheckFailed | CloudWatch (built-in) | 5 minutes (detailed: 1 minute) |
| EBS Volumes | VolumeReadOps, VolumeWriteOps, VolumeQueueLength, BurstBalance | CloudWatch (built-in) | 5 minutes |
| RDS Instances | CPUUtilization, FreeableMemory, ReadIOPS, WriteIOPS, DatabaseConnections, ReplicaLag | CloudWatch (built-in) | 1 minute (Enhanced Monitoring) |
| ALB/NLB | RequestCount, TargetResponseTime, HTTPCode_Target_5XX, HealthyHostCount, UnHealthyHostCount | CloudWatch (built-in) | 1 minute |
| NAT Gateway | BytesOutToDestination, PacketsDropCount, ErrorPortAllocation, ActiveConnectionCount | CloudWatch (built-in) | 1 minute |
| Transit Gateway | BytesIn, BytesOut, PacketsIn, PacketsOut, PacketDropCountBlackhole | CloudWatch (built-in) | 1 minute |
| Lambda Functions | Invocations, Errors, Duration, Throttles, ConcurrentExecutions | CloudWatch (built-in) | 1 minute |

### 4.2 Security Posture Metrics

| Component | Metric | Source | Collection Interval |
|---|---|---|---|
| Security Hub | Compliance score by standard (FSBP, NIST 800-53, CIS) | Security Hub | Continuous |
| Security Hub | Count of CRITICAL/HIGH/MEDIUM/LOW findings | Security Hub | Continuous |
| GuardDuty | Finding count by severity | GuardDuty | Continuous |
| AWS Config | Compliant vs. non-compliant rule count | AWS Config | Continuous |
| Macie | Sensitive data finding count | Macie | Every 15 minutes |
| IAM Access Analyzer | External access finding count | IAM Access Analyzer | Continuous |

### 4.3 Network Metrics

| Component | Metric | Source | Collection Interval |
|---|---|---|---|
| VPC Flow Logs | Accepted/Rejected packet counts, traffic by source/destination | CloudWatch Logs | 10-minute aggregation |
| Network Firewall | Alert count, flow count, dropped packets | CloudWatch Logs (ALERT + FLOW) | Continuous |
| VPC Endpoints | Packets processed, bytes processed | CloudWatch | 1 minute |

### 4.4 Cost Metrics

| Component | Metric | Source | Collection Interval |
|---|---|---|---|
| Account Spend | Monthly actual vs. budget | AWS Budgets | Daily |
| Service Spend | Cost by service, by account | Cost and Usage Report (CUR) | Monthly (Parquet) |

### 4.5 Collection Architecture

All metrics flow through the following centralized architecture:

1. **CloudWatch Metrics** — Collected natively in each account.
2. **CloudWatch Logs** — Application logs, VPC Flow Logs, Network Firewall logs, and Session Manager logs are sent to CloudWatch Logs in each account.
3. **Central Log Aggregation** — CloudWatch Logs are streamed to the LogArchive account's central S3 bucket via CloudWatch Logs subscription filters with dynamic partitioning.
4. **Log Retention** — CloudWatch Logs retain data for 365 days. Central S3 bucket retains logs for 1000 days with Glacier IR transition at 365 days.
5. **Security Findings** — Security Hub aggregates findings across all accounts and regions into the delegated Audit account with multi-region aggregation enabled.

---

## 5. Pillar 2: Application Logging

### 5.1 Standard Logging Requirements

All customer workloads must export application logs that capture:

- Application errors with stack traces and contextual metadata
- Request/response logs for API endpoints (with PII redacted)
- Authentication and authorization events
- Database query performance (slow query logs)
- Background job execution status and duration

### 5.2 Logging Implementation

| Log Type | Destination | Agent/Method | Retention |
|---|---|---|---|
| Application logs | CloudWatch Logs | CloudWatch Agent (deployed via SSM) | 365 days |
| OS-level logs (syslog, auth) | CloudWatch Logs | CloudWatch Agent | 365 days |
| ELB access logs | S3 (ELB log bucket) | Native ELB logging (auto-remediated via SSM) | 1000 days |
| VPC Flow Logs | CloudWatch Logs | Native VPC Flow Logs (ALL traffic) | 30 days (CloudWatch), 1000 days (S3) |
| Network Firewall logs | CloudWatch Logs | Native NFW logging (ALERT + FLOW) | 365 days |
| Session Manager logs | CloudWatch Logs | Native SSM Session Manager | 365 days |
| CloudTrail events | S3 (LogArchive) | Organization trail via Control Tower | 365 days (Glacier IR), 1000 days total |

### 5.3 Log Format Standards

- Application logs must use structured JSON format with the following minimum fields:
  - `timestamp` (ISO 8601)
  - `level` (ERROR, WARN, INFO, DEBUG)
  - `message`
  - `service` (application name)
  - `traceId` (for distributed tracing correlation)
- VPC Flow Logs use the extended custom format including: version, account-id, interface-id, srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, start, end, action, log-status, vpc-id, subnet-id, instance-id, tcp-flags, type, pkt-srcaddr, pkt-dstaddr, region, az-id, pkt-src-aws-service, pkt-dst-aws-service, flow-direction, traffic-path.

---

## 6. Pillar 3: Alerting Thresholds

### 6.1 Security Alerting

| Event | Severity | Notification Channel | Response SLA |
|---|---|---|---|
| GuardDuty HIGH severity finding | Critical | SNS → SecurityHigh email | 1 hour |
| GuardDuty MEDIUM severity finding | High | SNS → SecurityMedium email | 4 hours |
| GuardDuty LOW severity finding | Medium | SNS → SecurityLow email | 24 hours |
| Security Hub CRITICAL finding | Critical | SNS → SecurityHigh email | 1 hour |
| Security Hub HIGH finding | High | SNS → SecurityMedium email | 4 hours |
| Root user login detected | Critical | SNS → SecurityHigh email | Immediate |
| Config rule non-compliant (critical resource) | High | SNS → SecurityMedium email | 4 hours |
| Macie sensitive data finding | High | SNS → SecurityMedium email | 4 hours |

GuardDuty non-archived finding thresholds (enforced by AWS Config rule):
- High severity: must be archived within 1 day
- Medium severity: must be archived within 7 days
- Low severity: must be archived within 30 days

### 6.2 Operational Alerting

| Metric | Threshold | Severity | Action |
|---|---|---|---|
| EC2 CPUUtilization | > 90% for 5 minutes | Warning | Investigate, consider scaling |
| EC2 StatusCheckFailed | > 0 for 1 minute | Critical | Auto-recover or replace instance |
| RDS FreeableMemory | < 256 MB for 5 minutes | Warning | Investigate query patterns |
| RDS CPUUtilization | > 90% for 5 minutes | Warning | Consider instance resize |
| ALB UnHealthyHostCount | > 0 for 3 minutes | High | Investigate target health |
| ALB HTTPCode_Target_5XX | > 10 per minute | High | Investigate application errors |
| NAT Gateway ErrorPortAllocation | > 0 | Warning | Review connection patterns |
| Lambda Errors | > 5% of invocations | High | Investigate function code |
| Lambda Throttles | > 0 | Warning | Request concurrency increase |

### 6.3 Cost Alerting

| Threshold | Notification |
|---|---|
| 50% of monthly budget | Email to budget owner |
| 75% of monthly budget | Email to budget owner |
| 80% of monthly budget | Email to budget owner + management |
| 90% of monthly budget | Email to budget owner + management |
| 100% of monthly budget | Email to budget owner + management + executive sponsor |

---

## 7. Implementation Checklist

For each customer engagement, the following must be completed:

- [ ] CloudWatch Agent deployed to all EC2 instances via SSM
- [ ] VPC Flow Logs enabled (ALL traffic, custom fields, CloudWatch Logs destination)
- [ ] Network Firewall logging enabled (ALERT + FLOW to CloudWatch Logs)
- [ ] ELB access logging enabled (auto-remediated via Config rule + SSM document)
- [ ] Session Manager logging to CloudWatch Logs enabled
- [ ] Security Hub standards enabled (FSBP, NIST 800-53 Rev 5, CIS v3.0.0)
- [ ] GuardDuty enabled with S3 and EKS protection
- [ ] SNS topics configured (SecurityHigh, SecurityMedium, SecurityLow)
- [ ] AWS Budgets configured with threshold notifications
- [ ] CloudWatch dashboards created for key workload metrics
- [ ] Central log aggregation to LogArchive account verified
- [ ] Dynamic partitioning filters configured for log analysis

---

## 8. Revision History

| Version | Date | Author | Description |
|---|---|---|---|
| 1.0 | [DATE] | [AUTHOR] | Initial release |
