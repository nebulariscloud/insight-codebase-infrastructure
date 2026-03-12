# AWS Control Tower Service Delivery — Common Requirements
## Best-Practice Responses for Migration-to-AWS Customer References

> **Scenario**: Both customer references are migrations to AWS to begin their AWS journey.
> The solution uses AWS Control Tower + Landing Zone Accelerator (LZA) v1.14.1 with a hub-and-spoke network topology.
> Replace placeholder names (Customer #1 / Customer #2) with actual customer names.

---

## DOC-001 — Architecture Diagram

### Customer Reference #1
**Met?** Yes

**Partner Response:**
The customer is migrating on-premises workloads to AWS as part of a cloud-first initiative. The solution is deployed in an AWS Control Tower environment governed by Landing Zone Accelerator (LZA) v1.14.1 using a hub-and-spoke network topology.

The architecture diagram (attached) depicts:

**AWS Services Used:**
- AWS Control Tower, AWS Organizations, AWS IAM Identity Center
- AWS Transit Gateway (hub), AWS Network Firewall, NAT Gateways, Internet Gateways
- Amazon VPC (Ingress, Egress, Inspection, Endpoints, SharedServices, workload VPCs)
- AWS IPAM for automated IP address management
- VPC Interface Endpoints (EC2, ECR, KMS, SSM, CloudWatch Logs, Monitoring, etc.)
- Amazon S3, DynamoDB (Gateway Endpoints)
- AWS CloudTrail, AWS Config, Amazon GuardDuty, AWS Security Hub, Amazon Macie
- AWS Backup, Amazon CloudWatch, AWS Systems Manager
- AWS Network Firewall (stateful inspection)

**Deployment Layout:**
- AWS Organizations with OUs: Security, Infrastructure, Workloads/Dev, Workloads/Test, Workloads/Prod, Suspended
- Core accounts: Management, LogArchive, Audit, SharedServices, Network, Perimeter
- All VPCs deploy subnets across 2 Availability Zones (AZ-a and AZ-b)
- Transit Gateway in the Network account connects all VPCs via dedicated TGW attachment subnets
- Ingress VPC (Perimeter account): Internet Gateway, public subnets, firewall subnets, TGW attachment subnets
- Egress VPC (Perimeter account): NAT Gateways (one per AZ), public subnets, TGW attachment subnets
- Inspection VPC (Network account): AWS Network Firewall endpoints (one per AZ) with appliance mode enabled for symmetric routing
- Endpoints VPC (Network account): Centralized VPC interface endpoints shared across the organization
- SharedServices VPC: Web, App, and Data tier subnets across 2 AZs
- Workload VPCs (Dev/Test/Prod): Templated with App and Data subnets per AZ, auto-provisioned per account

**Scalability:**
- IPAM dynamically allocates CIDRs from a hierarchical pool structure (10.0.0.0/8 global → /12 regional → per-environment pools)
- VPC templates auto-provision identical network configurations for each new workload account
- NAT Gateways and Network Firewall scale automatically with traffic
- Centralized VPC endpoints reduce per-account overhead and scale with demand

**High Availability:**
- All VPCs span 2 AZs with independent subnets, route tables, and NAT Gateways per AZ
- Network Firewall endpoints deployed in both AZs with appliance mode for stateful symmetric routing
- Transit Gateway provides redundant cross-VPC connectivity
- In case of AZ failure, traffic automatically fails over to the surviving AZ through TGW routing and multi-AZ NAT/firewall deployments

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same architecture as Customer #1. The customer is migrating to AWS and the solution uses the identical LZA hub-and-spoke configuration with AWS Control Tower. Architecture diagram (attached) shows the multi-account structure with Transit Gateway hub, centralized inspection via AWS Network Firewall, ingress/egress separation, and workload VPCs across 2 AZs. Scalability is achieved through IPAM-managed IP allocation and VPC templates. High availability is ensured by multi-AZ deployments of all critical components.

---

## ACCT-001 — Secure AWS Account Governance Best Practice

### Customer Reference #1
**Met?** Yes

**Partner Response:**
Our organization maintains a documented Security Engagement SOP (attached) that governs AWS account creation and governance. The SOP covers:

1. **Root account usage**: Root credentials are never used for day-to-day workload activities. LZA enables Central Root User Management with `centralRootUserManagement` enabled, including `rootCredentialsManagement` and `allowRootSessions` capabilities. Root is only used for account-level tasks that explicitly require it (e.g., changing account-level settings). SCPs enforce restrictions preventing root account usage in member accounts via `lza-core-guardrails-2`.

2. **MFA on root**: MFA is enforced on the root account. AWS Control Tower enforces MFA on the management account root user. Security Hub standards (CIS AWS Foundations Benchmark v3.0.0 and AWS FSBP) continuously monitor and alert on root accounts without MFA.

3. **Contact information**: All accounts are created through AWS Control Tower Account Factory with corporate email addresses and contact information. Each account uses a dedicated corporate email alias (e.g., management@company.com, log-archive@company.com).

4. **CloudTrail logging**: AWS Control Tower enables an organization-wide CloudTrail trail across all regions. Logs are centralized in a dedicated S3 bucket in the LogArchive account with lifecycle policies (365-day transition to Glacier IR, 1000-day expiration). SCPs (`lza-core-guardrails-1`) prevent unauthorized modifications to CloudTrail configuration. CloudTrail security trail is validated via AWS Config rule `cloudtrail-security-trail-enabled`.

For Customer #1, all accounts were provisioned through Control Tower Account Factory. The LZA quarantine SCP is automatically applied to new accounts until the accelerator pipeline completes, preventing any unauthorized changes during provisioning.

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same governance practices applied. Refer to Customer #1 response and attached SOP documentation.

---

## ACCT-002 — Identity Security Best Practice (IAM)

### Customer Reference #1
**Met?** Yes

**Partner Response:**
Our Security Engagement SOP (attached) defines the standard approach for accessing customer AWS accounts:

**Console and Programmatic Access:**
- AWS IAM Identity Center (delegated to SharedServices account) provides centralized single sign-on for both AWS Management Console and CLI/programmatic access
- Users authenticate through Identity Center, which federates with the customer's existing enterprise identity provider
- No long-lived IAM access keys are created; all access uses temporary credentials via Identity Center session tokens

**Temporary Credentials and IAM Roles:**
- All cross-account access uses IAM roles with temporary credentials (STS AssumeRole)
- LZA configures `AWSControlTowerExecution` as the management account access role for orchestration
- EC2 instances use instance profiles (`EC2-Default-SSM-Role`) with SSM managed policies rather than embedded credentials
- Boundary policies (`lza-End-User-Policy`) are applied to limit maximum permissions

**Enterprise Identity Federation:**
- IAM Identity Center is enabled with `enableIdentityCenterAccess: true` in Control Tower configuration
- Customer's existing enterprise identities are federated through Identity Center
- Permission sets are mapped to organizational roles following least-privilege principles

**Least Privilege:**
- SCPs enforce guardrails at the organizational level, restricting actions across Security, Infrastructure, and Workload OUs
- Resource Control Policies (RCPs) enforce data perimeter controls
- IAM policies follow least-privilege: the sample end-user policy and SSM S3 policy demonstrate scoped permissions without wildcard Actions/Resources
- AWS Config rules monitor for inline policies (`iam-no-inline-policy-check`) and group membership (`iam-user-group-membership-check`)
- IAM Access Analyzer is enabled organization-wide to identify overly permissive policies

**Dedicated Credentials:**
- Every individual accessing AWS accounts uses their own Identity Center user profile with unique credentials
- No shared accounts or credentials are permitted

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same IAM practices applied. Refer to Customer #1 response and attached SOP documentation.

---

## OPE-001 — Workload Health KPIs

### Customer Reference #1
**Met?** Yes

**Partner Response:**
We provide standardized guidance (attached) for developing customer workload health KPIs with three components:

**Defining, Collecting, and Analyzing Workload Health Metrics:**
- Amazon CloudWatch is deployed across all accounts for metric collection and analysis
- CloudWatch Logs are centralized with 365-day retention (`cloudwatchLogRetentionInDays: 365`) and forwarded to the LogArchive account's central S3 bucket
- VPC Flow Logs capture all traffic (ALL traffic type) with 600-second aggregation intervals, including custom fields (vpc-id, subnet-id, instance-id, action, flow-direction, traffic-path) sent to CloudWatch Logs with 30-day retention
- GuardDuty findings are exported to S3 every 6 hours for trend analysis
- Security Hub aggregates findings across regions with multi-region aggregation enabled
- AWS Config continuously records resource configurations and evaluates compliance against 30+ rules

**Application Logging:**
- CloudWatch Logs agent deployed via SSM (`CloudWatchAgentServerPolicy` on EC2-Default-SSM-Role)
- Session Manager logs sent to CloudWatch Logs for audit trails
- Network Firewall ALERT and FLOW logs sent to CloudWatch Logs for network-level troubleshooting
- ELB access logging enabled with automated remediation via SSM document
- Dynamic partitioning filters applied to CloudWatch Logs for efficient log analysis

**Alerting Thresholds:**
- SNS topics configured for three severity levels: SecurityHigh, SecurityMedium, SecurityLow with email notifications
- AWS Budgets configured with threshold alerts at 50%, 75%, 80%, 90%, and 100% of budget
- GuardDuty findings monitored with Config rule thresholds: High severity (1 day), Medium (7 days), Low (30 days)
- Security Hub standards (FSBP, NIST 800-53 Rev 5, CIS v3.0.0) generate automated findings with severity ratings

For Customer #1, these KPIs were implemented during the migration. CloudWatch dashboards were created for key workload metrics, and the SNS alerting pipeline ensures the operations team is notified of security and operational events in real time.

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same KPI framework applied. Refer to Customer #1 response and attached standardized guidance.

---

## OPE-002 — Runbook/Playbook

### Customer Reference #1
**Met?** Yes

**Partner Response:**
We maintain a standardized runbook (attached) covering routine operational tasks and troubleshooting scenarios aligned with the KPIs defined in OPE-001:

- **Account Provisioning**: Step-by-step procedure for creating new accounts via Control Tower Account Factory, including LZA quarantine SCP workflow and pipeline execution
- **Adding OUs**: Procedure for extending the organizational structure (documented in docs/07-Operations/07-01-Adding-OUs)
- **Adding Accounts**: Procedure for onboarding new workload accounts (documented in docs/07-Operations/07-02-Adding-Accounts)
- **EC2 Instance Management**: SSM-based instance management procedures including instance profile attachment and patching (documented in docs/07-Operations/07-03-Managing-EC2-Instances)
- **Log Analysis**: Procedures for querying centralized logs in the LogArchive account, analyzing VPC Flow Logs, and investigating Network Firewall alerts (documented in docs/07-Operations/07-04-Log-Analysis)
- **Alarm Management**: Procedures for creating and managing CloudWatch alarms and SNS notifications (documented in docs/07-Operations/07-05-Creating-Managing-Alarms)
- **SCP Management**: Procedures for reviewing and updating Service Control Policies (documented in docs/07-Operations/07-06-Managing-SCPs)
- **Security Incident Response**: Playbook for responding to GuardDuty findings, Security Hub alerts, and Macie sensitive data findings
- **Network Troubleshooting**: Procedures for diagnosing connectivity issues using VPC Flow Logs, Network Firewall logs, and TGW route table analysis
- **Backup and Recovery**: Procedures for verifying AWS Backup jobs, initiating restores, and validating recovery points

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same runbook provided and customized for Customer #2's specific workloads.

---

## OPE-003 — Deployment Readiness

### Customer Reference #1
**Met?** Yes

**Partner Response:**
We use a consistent deployment process with the following components:

**Well-Defined Testing Process:**
- LZA configuration changes are committed to a CodeCommit/GitHub repository and go through a pull request review process
- The LZA pipeline validates configuration syntax and dependencies before deployment
- Changes are first tested in a Sandbox OU (with its own dedicated SCP `lza-core-sandbox-guardrails-1`) before promotion to Dev → Test → Prod
- New accounts are automatically quarantined (`quarantineNewAccounts: enable`) with a restrictive SCP until the LZA pipeline completes successfully

**Automated Testing Components:**
- LZA pipeline (AWS CodePipeline) automates the deployment of all infrastructure changes across accounts and regions
- AWS Config rules provide continuous compliance validation (30+ rules) with automated remediation for critical findings (e.g., EC2 instance profile attachment, ELB logging)
- Security Hub standards automatically validate security posture against FSBP, NIST 800-53 Rev 5, and CIS v3.0.0
- SCP revert changes config (`scpRevertChangesConfig: enable`) automatically reverts unauthorized manual SCP modifications

**Deployment Checklist:**
1. Configuration change committed and peer-reviewed
2. LZA pipeline syntax validation passes
3. Changes tested in Sandbox/Dev environment
4. Security Hub and Config compliance verified (zero critical findings)
5. Network connectivity validated (VPC Flow Logs, TGW routes)
6. Backup policies verified for new resources
7. Monitoring and alerting confirmed operational
8. Change promoted through Test → Prod via pipeline

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same deployment process applied. Refer to Customer #1 response.

---

## NETSEC-001 — VPC Network Security

### Customer Reference #1
**Met?** Yes

**Partner Response:**
Our network security best practices (documented and attached) are implemented as follows:

**Security Groups to Restrict Internet-to-VPC Traffic:**
- Default security group rules are deleted in all VPCs (`defaultSecurityGroupRulesDeletion: true`)
- Only the Ingress VPC (Perimeter account) and Egress VPC have Internet Gateways; all workload VPCs have `internetGateway: false`
- Inbound internet traffic enters only through the Ingress VPC's public subnets and is routed through Transit Gateway
- Declarative policies enforce VPC Block Public Access across Security, Workloads, Network, and SharedServices accounts

**Security Groups to Restrict Intra-VPC Traffic:**
- Workload VPCs use tiered subnets (App and Data) with separate route tables
- Data subnets have no routes to the internet or TGW (routes: []), isolating database-tier resources
- Security groups are configured per application tier following least-privilege (no default rules)

**Network ACLs:**
- Network ACLs provide an additional layer of defense at the subnet level
- Stateless rules restrict inbound and outbound traffic by protocol, port, and CIDR

**Additional AWS Security Services:**
- AWS Network Firewall in the Inspection VPC inspects all North-South and East-West traffic with stateful rule groups
- All spoke VPC traffic routes through the Inspection VPC via TGW route tables before reaching the Egress VPC
- VPC Flow Logs capture ALL traffic with custom fields including flow-direction and traffic-path for forensic analysis
- VPC endpoint policies restrict API access through centralized interface endpoints
- Control Tower controls detect unauthorized internet gateway attachments and unrestricted routes to IGWs

For Customer #1, the hub-and-spoke topology ensures all workload traffic is inspected by Network Firewall. Workload VPCs have no direct internet access; egress flows through NAT Gateways in the Perimeter account after inspection.

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same network security architecture applied. Refer to Customer #1 response.

---

## NETSEC-002 — Data Encryption

### Customer Reference #1
**Met?** Yes

**Partner Response:**
Our data encryption policy (attached) covers:

**Encryption in Transit:**
- All internet-facing endpoints use TLS. The Ingress VPC public subnets host load balancers configured for HTTPS/TLS termination
- VPC interface endpoints (EC2, ECR, KMS, SSM, CloudWatch Logs, etc.) use HTTPS by default
- VPC endpoint policies enforce secure access patterns
- Network Firewall rules can inspect and enforce TLS requirements for outbound traffic

**Encryption at Rest:**
- EBS default volume encryption is enabled organization-wide (`ebsDefaultVolumeEncryption: enable: true`) using customer-managed KMS keys
- S3 public access block is enabled across all accounts (`s3PublicAccessBlock: enable: true`)
- AWS Config rules enforce encryption: `dynamodb-table-encrypted-kms`, `sagemaker-endpoint-configuration-kms-key-configured`, `sagemaker-notebook-instance-kms-key-configured`, `cloudwatch-log-group-encrypted`, `backup-recovery-point-encrypted`, `codebuild-project-artifact-encryption`
- Control Tower controls enforce CloudWatch Log Group encryption with KMS
- Central logging S3 buckets use server-side encryption with lifecycle transitions to Glacier IR

**Key Management:**
- AWS KMS is used as the dedicated key management solution
- KMS is accessible via centralized VPC interface endpoint in the Endpoints VPC
- Secrets Manager uses customer-managed KMS keys (enforced by Config rule `secretsmanager-using-cmk`)
- IAM Access Analyzer monitors for overly permissive key policies

For Customer #1, all data stores are encrypted at rest using KMS, and all API traffic uses TLS via VPC endpoints or HTTPS endpoints.

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same encryption policy applied. Refer to Customer #1 response.

---

## REL-001 — Deployment Automation / Infrastructure-as-Code

### Customer Reference #1
**Met?** Yes

**Partner Response:**
All infrastructure is deployed using Infrastructure-as-Code through Landing Zone Accelerator (LZA):

- LZA uses AWS CloudFormation under the hood to deploy and manage all resources across the multi-account environment
- The entire landing zone is defined in YAML configuration files: `accounts-config.yaml`, `organization-config.yaml`, `network-config.yaml`, `security-config.yaml`, `global-config.yaml`, `iam-config.yaml`, and `replacements-config.yaml`
- A `replacements-config.yaml` provides parameterized values (CIDR ranges, email addresses, region settings) enabling consistent, repeatable deployments
- The LZA pipeline (AWS CodePipeline + CodeBuild) automates deployment across all accounts and regions — no manual Console changes
- VPC templates (`vpcTemplates`) automatically provision identical network configurations for new workload accounts in Dev, Test, and Prod OUs
- SCPs, tagging policies, backup policies, and Config rules are all defined as code and deployed through the pipeline
- SSM Automation documents (e.g., `enable-elb-logging.yaml`, `attach-iam-instance-profile.yaml`) provide automated remediation as code
- SCP revert changes config ensures any manual SCP modifications are automatically reverted

**Evidence:** LZA configuration files (this repository) serve as the CloudFormation template evidence. The pipeline architecture diagram shows the CI/CD flow from code commit → validation → multi-account deployment.

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same IaC approach using LZA. Refer to Customer #1 response and attached configuration artifacts.

---

## REL-002 — Disaster Recovery (RTO/RPO)

### Customer Reference #1
**Met?** Yes

**Partner Response:**
Resilience is a core discussion point in our customer engagements:

**RTO & RPO Targets:**
- We establish RTO/RPO targets during the migration planning phase based on the customer's business requirements
- For this engagement, the following targets were discussed:
  - Production workloads: RTO 4 hours / RPO 1 hour (supported by hourly and continuous backup plans)
  - Non-production workloads: RTO 24 hours / RPO 24 hours (supported by daily backup plans)

**Recovery Process for Core Architecture Components:**
- AWS Backup is configured organization-wide with multiple backup plans: Continuous, Hourly, Daily, Weekly, Monthly
- Backup retention: 1 year standard, 35 days continuous, 2 years for monthly backups
- VSS-enabled backups for Windows workloads
- Backup vaults deployed to Infrastructure and Workload OUs (`lza-BackupVault`)
- Backup recovery points are encrypted (enforced by Config rule `backup-recovery-point-encrypted`)
- Manual deletion of recovery points is disabled (enforced by Config rule and Control Tower control)
- EC2 instances, EBS volumes, RDS, Aurora, and S3 are all protected by backup plans (enforced by Config rules: `ebs-in-backup-plan`, `rds-in-backup-plan`, `aurora-resources-protected-by-backup-plan`, `ec2-resources-protected-by-backup-plan`)
- Multi-AZ deployment across all VPCs provides infrastructure-level resilience
- Transit Gateway and Network Firewall span 2 AZs for network-layer recovery

**Customer Awareness:**
- RTO/RPO targets are documented and communicated to the customer during the design phase
- Backup plan tag policies enforce consistent tagging across the organization, ensuring all resources are assigned to appropriate backup plans
- Regular backup restore testing is recommended as part of the operational runbook

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same resilience framework applied. RTO/RPO targets were discussed and documented based on Customer #2's specific business requirements.

---

## COST-001 — Cost Optimization / TCO Analysis

### Customer Reference #1
**Met?** Yes

**Partner Response:**
We conduct TCO analysis for all migration engagements:

**Inputs Used to Estimate Cost:**
- Current on-premises infrastructure inventory (compute, storage, networking, licensing)
- AWS Pricing Calculator estimates for target architecture (EC2, VPC, Transit Gateway, Network Firewall, NAT Gateways, S3, CloudWatch, etc.)
- Data transfer costs (ingress/egress, inter-AZ, inter-region)
- Operational costs (monitoring, backup, security services)
- Licensing considerations (BYOL vs. included)

**Cost Estimates Provided Before Implementation:**
- AWS Cost and Usage Reports (CUR) are configured in Parquet format with monthly granularity for ongoing cost tracking
- AWS Budgets are configured with a monthly threshold and notifications at 50%, 75%, 80%, 90%, and 100% of budget
- Pre-migration cost model provided to the customer comparing on-premises TCO vs. AWS projected costs over 1, 3, and 5 year horizons

**Business Value Analysis:**
- Migration to AWS eliminates capital expenditure for hardware refresh cycles
- Operational efficiency gains from automated infrastructure provisioning (LZA pipeline), automated security compliance (Config rules with remediation), and centralized monitoring
- Reduced time-to-market for new workloads via VPC templates and Account Factory
- Improved security posture through automated guardrails, reducing risk and potential breach costs
- Cost optimization through right-sizing recommendations, Reserved Instances/Savings Plans analysis, and S3 lifecycle policies (Glacier IR transitions at 365 days)

**Evidence:** Cost analysis report and AWS Pricing Calculator estimates provided to the customer (attached).

### Customer Reference #2
**Met?** Yes

**Partner Response:**
Same TCO analysis methodology applied. Cost model customized for Customer #2's specific workload profile and migration scope.
