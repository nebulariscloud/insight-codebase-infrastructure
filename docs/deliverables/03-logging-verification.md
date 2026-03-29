# Centralized Logging Verification

## Logging Architecture Summary

| Log Source | Destination | Retention | Account |
|---|---|---|---|
| CloudTrail (org trail) | Control Tower S3 bucket | 1000 days (Glacier IR at 365d) | LogArchive |
| AWS Config snapshots | Central Logs S3 bucket | 1000 days (Glacier IR at 365d) | LogArchive |
| VPC Flow Logs | CloudWatch Logs (30d) then S3 | 30d CloudWatch + 1000d S3 | LogArchive |
| SSM Session Manager | CloudWatch Logs then S3 | 365d CloudWatch + 1000d S3 | LogArchive |
| GuardDuty findings | S3 export | Every 6 hours | LogArchive |
| ELB access logs | ELB Logs S3 bucket | 1000 days (Glacier IR at 365d) | LogArchive |
| S3 access logs | S3 Access Logs bucket | 1000 days (Glacier IR at 365d) | LogArchive |
| Security Hub findings | Aggregated in Audit account | Continuous | Audit |
| CloudWatch Logs (all) | Replicated to S3 via subscription filters | Dynamic partitioning | LogArchive |

## S3 Buckets in LogArchive Account

| Bucket | Naming Pattern | Purpose |
|---|---|---|
| CloudTrail Logs | aws-controltower-cloudtrail-logs-808431466229-* | CloudTrail org trail (managed by Control Tower) |
| Central Logs | aws-accelerator-central-logs-808431466229-us-east-2 | Config, VPC Flow Logs, replicated CloudWatch Logs |
| S3 Access Logs | aws-accelerator-s3-access-logs-{ACCOUNT_ID}-{REGION} | Access logging for all LZA-managed S3 buckets |
| ELB Access Logs | aws-accelerator-elb-access-logs-{ACCOUNT_ID}-{REGION} | Elastic Load Balancer access logs |

## S3 Lifecycle Policy (all LZA buckets)

| Stage | Timing | Storage Class |
|---|---|---|
| Initial storage | Day 0 | S3 Standard |
| Transition | Day 365 | Glacier Instant Retrieval |
| Expiration (current version) | Day 1000 | Deleted |
| Expiration (noncurrent version) | Day 1000 | Deleted |
| Incomplete multipart upload cleanup | Day 7 | Deleted |

## CloudWatch Logs Dynamic Partitioning

Logs replicated from CloudWatch to S3 are organized by prefix:

| Log Group Pattern | S3 Prefix |
|---|---|
| /AWSAccelerator-SecurityHub | security-hub |
| AWSAccelerator-sessionmanager-logs | session-manager |
| AWSAccelerator-*FirewallAlertLogGroup* | network-firewall/alert |
| AWSAccelerator-*FirewallFlowLogGroup* | network-firewall/flow |
| AWSAccelerator-*FlowLogsGroup* | vpc-flow-logs |
| /aws/lambda/* | lambda |
| /aws/codebuild/* | codebuild |
| StackSet-AWSControlTowerBP* | AWSControlTowerBP |

## Verification Evidence

### 1. CloudTrail

CloudTrail is managed by AWS Control Tower via an organization-level trail. Logs are delivered to the Control Tower-managed bucket.

Bucket: `aws-controltower-cloudtrail-logs-808431466229-*`
Path: `AWSLogs/o-5w8kebrqmm/{account-id}/`

Verified: Account ID folders exist for all 12 accounts.

<!-- Insert screenshot: S3 bucket showing account ID folders under AWSLogs/o-5w8kebrqmm/ -->

### 2. AWS Config

Config snapshots are delivered to the LZA central-logs bucket.

Bucket: `aws-accelerator-central-logs-808431466229-us-east-2`
Path: `AWSLogs/{account-id}/Config/{region}/`

Verified: Config snapshots present from multiple accounts.

<!-- Insert screenshot: S3 bucket showing Config folder with account ID subfolders -->

### 3. VPC Flow Logs

VPC Flow Logs are sent to CloudWatch Logs in VPC-owning accounts, then replicated to S3 via subscription filters.

Bucket: `aws-accelerator-central-logs-808431466229-us-east-2`
Path: `CloudWatchLogs/vpc-flow-logs/`

Verified: Flow log data present from Network and Perimeter accounts.

<!-- Insert screenshot: S3 bucket showing vpc-flow-logs prefix with data -->

### 4. Session Manager

Session Manager logs are generated when users connect to EC2 instances via SSM. No EC2 instances have been launched yet, so no session logs exist. The configuration is in place and logs will replicate to the `session-manager/` prefix once sessions occur.

### 5. GuardDuty Export

GuardDuty findings are exported to S3 every 6 hours from the Audit account.

Verified: S3 export configured with 6-hour frequency pointing to LogArchive bucket.

<!-- Insert screenshot: GuardDuty settings showing S3 export configuration -->

### 6. Security Hub Aggregation

Security Hub aggregates findings from all member accounts with cross-region aggregation enabled. All AWS regions are linked for aggregation as a security best practice, ensuring findings from any region are captured centrally.

Verified: Region aggregation enabled, findings visible from all member accounts across all regions.

<!-- Insert screenshot: Security Hub showing cross-account findings and linked regions -->
