# Service Control Policies & Guardrails

## Service Control Policies (SCPs)

| Policy Name | Attached To | Description |
|---|---|---|
| Core-Guardrails-1 | Infrastructure OU, Security OU, Workloads OU | Restricts unauthorized modifications to CloudTrail, AWS Config, and LZA-managed resources. Enforces encryption for EBS, EFS, RDS, and Aurora. Protects LZA configuration buckets, Lambda functions, SNS topics, and KMS keys. |
| Core-Guardrails-2 | Infrastructure OU, Security OU, Workloads OU | Restricts unauthorized modifications to GuardDuty, SecurityHub, and Macie. Protects LZA-deployed CloudFormation stacks and SSM parameters. Prevents use of root account and creation of IAM users (enforces federated access via Identity Center). |
| Security-Guardrails-1 | Audit account, LogArchive account | Restricts unauthorized modifications to networking resources and configurations. Enforces encryption requirements for storage services. Attached at account level to reserve SCP quota for Control Tower region deny controls. |
| Infrastructure-Guardrails-1 | Network account, Perimeter account, SharedServices account | Restricts unauthorized modifications to networking resources (VPCs, Transit Gateways, Route Tables). Prevents creation of security groups with unrestricted internet access. Blocks high-risk services (Lightsail, GameLift, AppFlow). Restricts AWS Marketplace transactions. |
| Workloads-Guardrails-1 | Workloads/Dev, Workloads/Test, Workloads/Prod | Restricts unauthorized modifications to networking resources and configurations. Enforces encryption requirements for storage services. |
| Sandbox-Guardrails-1 | Workloads/Sandbox | Restricts unauthorized modifications to networking resources and configurations. Enforces encryption requirements for storage services. Sandbox-specific restrictions. |
| Suspended-Guardrails | Suspended OU | Restricts all LZA access to resources. DenyAll policy for decommissioned or quarantined accounts. |
| Quarantine | Auto-applied to new accounts | Prevents almost all service actions until the account is fully provisioned by LZA. Automatically removed after LZA pipeline configures the account. |

## Resource Control Policies (RCPs)

| Policy Name | Attached To | Description |
|---|---|---|
| Core-Rcp-Guardrails | Infrastructure OU, Security OU, Workloads OU | Comprehensive data perimeter policy. Allows external read-only access while protecting AWS resources from unauthorized modifications. Enforces secure communications. |

## Declarative Policies

| Policy Name | Attached To | Description |
|---|---|---|
| VPC Block Public Access | Security OU, Workloads/Dev, Workloads/Test, Workloads/Prod, Network account, SharedServices account | Prevents public VPC access at the account level. Applied granularly at account level as some accounts within OUs require exemptions (e.g., Perimeter account needs public access for ingress/egress). |

## AWS Control Tower Controls (11 enabled)

| Control | Identifier | Deployed To |
|---|---|---|
| CloudTrail S3 data events logging | 1m3wi9y66gi199vwyqmu4lm4l | Security, Infrastructure, Workloads (all sub-OUs) |
| CloudWatch Log Group encryption | 497wrm2xnk1wxlf4obrdo7mej | Security, Infrastructure, Workloads (all sub-OUs) |
| IAM group has users check | 3jw8po9x95lr2nob65iaqhqir | Security, Infrastructure, Workloads (all sub-OUs) |
| IAM no inline policy check | bi738zni6ovf9d6dagobqtk6g | Security, Infrastructure, Workloads (all sub-OUs) |
| Internet gateway authorized VPC only | 1d908j9c0qtyr5vq7mora1ht2 | Security, Infrastructure, Workloads (all sub-OUs) |
| No unrestricted route to IGW | b8pjfqosgkgknznstduvel4rh | Security, Infrastructure, Workloads (all sub-OUs) |
| SageMaker notebook KMS key configured | 3b7ib9mi87kcw90atgx2nboax | Security, Infrastructure, Workloads (all sub-OUs) |
| Security Hub enabled | 1klk5z4sby5l0cfx65dmq2dsk | Security, Infrastructure, Workloads (all sub-OUs) |
| Backup plan min frequency and retention | dagreqi0i3fitenunuuo4q64t | Security, Infrastructure, Workloads (all sub-OUs) |
| Backup recovery point manual deletion disabled | d1wltz1jx8c4aok5062g4kzz3 | Security, Infrastructure, Workloads (all sub-OUs) |
| EC2 instances protected by backup plan | aqh482zxh1libhd8e5pff5r1w | Security, Infrastructure, Workloads (all sub-OUs) |
