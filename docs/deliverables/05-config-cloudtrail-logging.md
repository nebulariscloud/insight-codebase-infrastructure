# AWS Config & CloudTrail Centralized Logging Configuration

## AWS CloudTrail

### Organization Trail

| Setting | Value |
|---|---|
| Managed By | AWS Control Tower |
| Trail Type | Organization trail |
| Scope | All accounts in the organization |
| Multi-Region | Yes |
| Global Service Events | Yes |
| Management Events | Yes |
| S3 Data Events | Yes (enabled via Control Tower control) |
| Log Destination | Central Logs S3 bucket in LogArchive account |
| LZA CloudTrail | Disabled (to avoid duplication with Control Tower trail) |

### Why LZA CloudTrail is Disabled

The LZA configuration explicitly disables its own CloudTrail to avoid creating duplicate trails. Control Tower already provisions an organization-level trail that covers all accounts and regions. The relevant configuration in `global-config.yaml`:

```yaml
cloudtrail:
  enable: false
  organizationTrail: false
```

Control Tower's trail configuration:

```yaml
controlTower:
  enable: true
  landingZone:
    logging:
      organizationTrail: true
```

## AWS Config

### Configuration Recorder & Delivery Channel

| Setting | Value |
|---|---|
| Configuration Recorder | Enabled in all accounts |
| Delivery Channel | Enabled in all accounts |
| Service Linked Role | Yes |
| Delegated Admin | Audit account |
| Config Snapshots | Delivered to Central Logs S3 bucket in LogArchive |

### AWS Config Rules (27 rules deployed)

#### All Accounts (Root OU)

| Rule Name | Resource Type | Description |
|---|---|---|
| iam-user-group-membership-check | IAM::User | Checks IAM users belong to at least one group |
| cloudtrail-enabled | Global | Checks CloudTrail is enabled |
| emr-kerberos-enabled | Global | Checks EMR clusters have Kerberos enabled |
| s3-bucket-policy-grantee-check | S3::Bucket | Checks S3 bucket policies for overly permissive grantees |
| ec2-instance-detailed-monitoring-enabled | EC2::Instance | Checks EC2 detailed monitoring is enabled |
| ec2-volume-inuse-check | EC2::Volume | Checks EBS volumes are attached and delete on termination |
| guardduty-non-archived-findings | Global | Checks for non-archived GuardDuty findings (1d high, 7d medium, 30d low) |
| sagemaker-endpoint-configuration-kms-key-configured | Global | Checks SageMaker endpoints use KMS encryption |
| dynamodb-table-encrypted-kms | DynamoDB::Table | Checks DynamoDB tables use KMS encryption |
| account-part-of-organizations | Global | Checks account is part of AWS Organizations |
| codebuild-project-artifact-encryption | CodeBuild::Project | Checks CodeBuild artifacts are encrypted |
| dynamodb-throughput-limit-check | Global | Checks DynamoDB throughput limits |
| ebs-optimized-instance | EC2::Instance | Checks EC2 instances are EBS-optimized |
| lambda-dlq-check | Lambda::Function | Checks Lambda functions have dead letter queues |
| secretsmanager-using-cmk | SecretsManager::Secret | Checks Secrets Manager uses customer managed keys |
| api-gw-cache-enabled-and-encrypted | ApiGateway::Stage | Checks API Gateway cache is encrypted |
| cloudtrail-security-trail-enabled | Global | Checks security trail is enabled |
| ebs-in-backup-plan | Global | Checks EBS volumes are in a backup plan |
| ec2-instances-in-vpc | EC2::Instance | Checks EC2 instances are in a VPC |
| rds-in-backup-plan | Global | Checks RDS instances are in a backup plan |
| aurora-resources-protected-by-backup-plan | RDS::DBCluster | Checks Aurora clusters are backed up |
| backup-recovery-point-encrypted | Backup::RecoveryPoint | Checks backup recovery points are encrypted |
| ec2-instance-profile-attached | EC2::Instance | Checks EC2 instances have instance profiles (auto-remediation enabled) |
| elb-logging-enabled | ELB, ELBv2 | Checks ELB access logging is enabled (auto-remediation enabled) |

#### Management Account Only (additional rules)

| Rule Name | Description |
|---|---|
| securityhub-enabled | Checks Security Hub is enabled |
| cloudtrail-s3-dataevents-enabled | Checks CloudTrail S3 data events are enabled |
| iam-group-has-users-check | Checks IAM groups have at least one user |
| internet-gateway-authorized-vpc-only | Checks IGWs are attached to authorized VPCs |
| iam-no-inline-policy-check | Checks for inline policies on users, roles, groups |
| cloudwatch-log-group-encrypted | Checks CloudWatch Log Groups are encrypted |
| sagemaker-notebook-instance-kms-key-configured | Checks SageMaker notebooks use KMS |
| no-unrestricted-route-to-igw | Checks route tables for unrestricted IGW routes |
| backup-plan-min-frequency-and-min-retention-check | Checks backup plan frequency and retention |
| backup-recovery-point-manual-deletion-disabled | Checks backup vault prevents manual deletion |
| ec2-resources-protected-by-backup-plan | Checks EC2 instances are protected by backup |

### Automated Remediation

| Rule | Remediation Action | Target |
|---|---|---|
| ec2-instance-profile-attached | Attach IAM instance profile (EC2-Default-SSM-Role) | SSM Automation document |
| elb-logging-enabled | Enable ELB access logging to central bucket | SSM Automation document |

Both remediations run automatically with up to 5 retry attempts at 60-second intervals.
