# Centralized Logging Verification

## Logging Architecture Summary

| Log Source | Destination | Retention | Account |
|---|---|---|---|
| CloudTrail (org trail) | Central Logs S3 bucket | 1000 days (Glacier IR at 365d) | LogArchive |
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
| Central Logs | aws-accelerator-central-logs-{ACCOUNT_ID}-{REGION} | CloudTrail, Config, VPC Flow Logs, replicated CloudWatch Logs |
| S3 Access Logs | aws-accelerator-s3-access-logs-{ACCOUNT_ID}-{REGION} | Access logging for all LZA-managed S3 buckets |
| ELB Access Logs | aws-accelerator-elb-access-logs-{ACCOUNT_ID}-{REGION} | Elastic Load Balancer access logs |

## S3 Lifecycle Policy (all buckets)

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

## Verification Steps

To verify logging is working correctly, perform the following checks:

### 1. CloudTrail Verification
Log into the LogArchive account. Navigate to S3 and open the central-logs bucket. Confirm you see CloudTrail log objects from multiple account IDs under the CloudTrail prefix. Verify logs exist from at least: Management, LogArchive, Audit, SharedServices, Network, Perimeter accounts.

### 2. AWS Config Verification
In the same central-logs bucket, confirm AWS Config snapshots and configuration history files are present from multiple accounts.

### 3. VPC Flow Logs Verification
Check CloudWatch Logs in any member account for log groups matching *FlowLogsGroup*. Confirm the central-logs bucket has vpc-flow-logs prefix with data from multiple accounts.

### 4. Session Manager Verification
Check CloudWatch Logs in any member account for log groups matching *sessionmanager-logs*. Confirm session-manager prefix exists in central-logs bucket.

### 5. GuardDuty Export Verification
Log into the Audit account. Navigate to GuardDuty settings. Confirm S3 export is configured with 6-hour frequency pointing to the LogArchive bucket.

### 6. Security Hub Aggregation Verification
Log into the Audit account. Navigate to Security Hub. Confirm region aggregation is enabled and findings are visible from all member accounts and all enabled regions (us-east-2, us-east-1, us-west-2).

## Evidence Capture

For each verification step above, capture:
- Screenshot of S3 bucket contents showing log objects from multiple accounts
- Screenshot of CloudWatch Log Groups in member accounts
- Screenshot of GuardDuty export configuration
- Screenshot of Security Hub showing cross-account, cross-region findings
