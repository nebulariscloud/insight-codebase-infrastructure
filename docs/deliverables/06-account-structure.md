# Account Structure — OUs, Accounts, and Roles

## Organizational Unit Hierarchy

```
Root
├── Management Account (066971257969)
├── Security OU
│   ├── LogArchive (808431466229)
│   └── Audit (021655151355)
├── Infrastructure OU
│   ├── SharedServices (547368325532)
│   ├── Network (857876979853)
│   └── Perimeter (713939170920)
├── Workloads OU
│   ├── Sandbox
│   │   └── Sandbox (470337543799)
│   ├── Dev
│   │   └── Development (070502825675)
│   ├── Test
│   │   ├── Staging (870150364800)
│   │   ├── QA (806997205179)
│   │   └── UAT (832511099188)
│   └── Prod
│       └── Production (395516496764)
└── Suspended OU (ignored)
```

## SOW to LZA OU Mapping

| SOW OU Name | LZA OU Name | Notes |
|---|---|---|
| Security OU | Security | Exact match |
| Shared Services OU | Infrastructure | LZA places SharedServices, Network, and Perimeter here |
| Production OU | Workloads/Prod | Nested under Workloads |
| Staging OU | Workloads/Test | SOW "Staging" maps to LZA "Test" |
| Non-Prod OU | Workloads/Dev + Workloads/Test | SOW combines Dev/QA/UAT; LZA separates Dev and Test |
| Sandbox OU | Workloads/Sandbox | Nested under Workloads |

## SOW "Security Services Account" Mapping

The SOW specifies a "Security Services Account" for centralized security tooling. In the LZA architecture, the Audit account serves this function as the delegated administrator for:

- Amazon GuardDuty (threat detection)
- AWS Security Hub (security posture management)
- Amazon Macie (sensitive data discovery)
- AWS Config (configuration compliance)
- IAM Access Analyzer (resource exposure analysis)

This is the AWS-recommended pattern per the AWS Security Reference Architecture. A separate "Security Services" account is not needed.

## Account Details

### Mandatory Accounts

| Account | ID | Email | OU | Purpose |
|---|---|---|---|---|
| Management | 066971257969 | insightgroup-management@nebulariscloud.com | Root | AWS Organizations, Control Tower, LZA pipeline |
| LogArchive | 808431466229 | insightgroup-log-archive@nebulariscloud.com | Security | Centralized log storage (CloudTrail, Config, VPC Flow Logs) |
| Audit | 021655151355 | insightgroup-audit@nebulariscloud.com | Security | Delegated admin for security services |

### Infrastructure Accounts

| Account | ID | Email | OU | Purpose |
|---|---|---|---|---|
| SharedServices | 547368325532 | insightgroup-shared@nebulariscloud.com | Infrastructure | Identity Center delegation, shared org services |
| Network | 857876979853 | insightgroup-network@nebulariscloud.com | Infrastructure | Transit Gateway, IPAM, Shared VPCs, DNS |
| Perimeter | 713939170920 | insightgroup-perimeter@nebulariscloud.com | Infrastructure | Ingress/Egress VPCs, NAT Gateways, internet boundary |

### Workload Accounts

| Account | ID | Email | OU | Purpose |
|---|---|---|---|---|
| Production | 395516496764 | insightgroup-production@nebulariscloud.com | Workloads/Prod | Production workloads |
| Staging | 870150364800 | insightgroup-staging@nebulariscloud.com | Workloads/Test | Pre-production / staging |
| Development | 070502825675 | insightgroup-development@nebulariscloud.com | Workloads/Dev | Feature development |
| QA | 806997205179 | insightgroup-qa@nebulariscloud.com | Workloads/Test | Quality assurance and integration testing |
| UAT | 832511099188 | insightgroup-uat@nebulariscloud.com | Workloads/Test | User acceptance testing |
| Sandbox | 470337543799 | insightgroup-sandbox@nebulariscloud.com | Workloads/Sandbox | Experimentation and PoC |

## Roles in Every Account

| Role | Assumed By | Purpose |
|---|---|---|
| AWSControlTowerExecution | Management account | Cross-account orchestration for LZA and Control Tower |
| EC2-Default-SSM-Role | ec2.amazonaws.com | SSM Session Manager access, CloudWatch agent |
| Backup-Role | backup.amazonaws.com | AWS Backup operations |
