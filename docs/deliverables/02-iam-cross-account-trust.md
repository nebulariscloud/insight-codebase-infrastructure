# IAM Cross-Account Trust & Role Setup

## Cross-Account Access Model

### Management Account Access Role

| Setting | Value |
|---|---|
| Role Name | AWSControlTowerExecution |
| Exists In | All member accounts |
| Trusted Principal | Management account |
| Purpose | LZA pipeline orchestration and cross-account resource deployment |
| How It Works | LZA CodePipeline/CodeBuild assumes this role into each member account to deploy CloudFormation stacks, configure services, and manage resources |

### AWS IAM Identity Center (SSO)

| Setting | Value |
|---|---|
| Service | AWS IAM Identity Center |
| Delegated Admin | SharedServices account |
| Purpose | Centralized federated access for all human users |
| Scope | Organization-wide |

## IAM Roles Deployed to All Accounts

### EC2-Default-SSM-Role

| Setting | Value |
|---|---|
| Deployed To | All accounts except Management |
| Assumed By | ec2.amazonaws.com (service role) |
| Instance Profile | Yes (attached to EC2 instances automatically) |
| AWS Managed Policies | AmazonSSMManagedInstanceCore, CloudWatchAgentServerPolicy |
| Custom Policies | Default-SSM-S3-Policy (access to SSM-required S3 resources) |
| Permissions Boundary | End-User-Policy |
| Purpose | Enables SSM Session Manager access to EC2 instances without SSH keys or open inbound ports. Enables CloudWatch agent for monitoring. |

### Backup-Role

| Setting | Value |
|---|---|
| Deployed To | All accounts except Management |
| Assumed By | backup.amazonaws.com (service role) |
| AWS Managed Policies | AWSBackupServiceRolePolicyForBackup, AWSBackupServiceRolePolicyForRestores |
| Purpose | Used by AWS Backup plans defined in organization-config.yaml to perform scheduled backups and restores |

## IAM Policies Deployed to All Accounts

### End-User-Policy

| Setting | Value |
|---|---|
| Type | Customer managed policy |
| Deployed To | All accounts except Management |
| Source | iam-policies/sample-end-user-policy.json |
| Purpose | Permissions boundary that limits the maximum permissions development teams can grant when creating their own roles |

### Default-SSM-S3-Policy

| Setting | Value |
|---|---|
| Type | Customer managed policy |
| Deployed To | All accounts except Management |
| Source | iam-policies/ssm-s3-policy.json |
| Purpose | Allows EC2 instances to access S3 resources required for SSM agent operation |

## Delegated Administration Roles

| Service | Delegated Admin Account | Scope |
|---|---|---|
| AWS Security Hub | Audit | Organization-wide, all regions |
| Amazon GuardDuty | Audit | Organization-wide, all regions |
| Amazon Macie | Audit | Organization-wide, all regions |
| AWS Config | Audit | Organization-wide, all regions |
| IAM Access Analyzer | Audit | Organization-wide |
| AWS IPAM | Network | Organization-wide |
| AWS IAM Identity Center | SharedServices | Organization-wide |

## Security Controls on IAM

- IAM user creation is blocked by SCP (Core-Guardrails-2) — all human access must go through Identity Center
- Root account usage is blocked by SCP (Core-Guardrails-2)
- IAM password policy enforced: 14 char minimum, uppercase + lowercase + symbols + numbers required, 90-day max age, 24 password history, no hard expiry
