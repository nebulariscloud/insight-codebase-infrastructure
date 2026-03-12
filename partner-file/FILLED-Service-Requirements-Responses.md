# AWS Control Tower Service Delivery — Service Requirements (CT-specific)
## Best-Practice Responses for Migration-to-AWS Customer References

> **Scenario**: Both customer references are migrations to AWS to begin their AWS journey.
> The solution uses AWS Control Tower + Landing Zone Accelerator (LZA) v1.14.1 with a hub-and-spoke network topology.
> Replace placeholder names (Borinquen / IRSI) with actual customer names.

---

## CT-001 — Environment Setup Using AWS Control Tower

### Customer Reference #1 (Borinquen)
**Met?** Yes

**Partner Response:**
Yes, the solution is deployed in an AWS Control Tower environment.

**Customer Problem Statement:**
The customer had no existing AWS presence and needed to establish a secure, scalable, multi-account AWS environment to migrate their on-premises workloads. They required centralized governance, automated account provisioning, consistent security guardrails, and compliance monitoring from day one — without building these capabilities from scratch.

**How the Solution Addresses the Issue:**
AWS Control Tower was deployed as the foundation for the multi-account landing zone, providing:
- Centralized governance through AWS Organizations with a well-defined OU structure (Security, Infrastructure, Workloads/Dev, Workloads/Test, Workloads/Prod, Suspended)
- Automated account provisioning via Account Factory, ensuring every new account inherits consistent security baselines
- Built-in guardrails (preventive and detective controls) deployed across all OUs
- IAM Identity Center integration (`enableIdentityCenterAccess: true`) for centralized SSO access management
- Organization-wide CloudTrail trail for audit logging
- Landing Zone version 4.0 with 365-day log retention for both logging and access logging buckets

**Challenges/Objections:**
No significant objections to using AWS Control Tower. The customer recognized the value of a managed landing zone service for their greenfield AWS deployment. The primary consideration was ensuring Control Tower's guardrails aligned with their compliance requirements, which was addressed by layering additional SCPs and Config rules through LZA.

### Customer Reference #2 (IRSI)
**Met?** Yes

**Partner Response:**
Yes, the solution is deployed in an AWS Control Tower environment. The customer was also a greenfield migration with no prior AWS infrastructure. AWS Control Tower provided the governance foundation, and LZA extended it with customized security controls and networking. No objections to Control Tower adoption.

---

## CT-002 — Deployment Patterns on AWS Control Tower

### Customer Reference #1 (Borinquen)
**Met?** Yes

**Partner Response:**
The solution follows the **Migration to AWS** deployment pattern, combined with **Networking (VPC, Transit Gateway, DNS)** and **Management and Governance (Custom Guardrails and SCPs, Account Factory)**.

**Solution Description and How It Leverages Control Tower:**

The architecture (see attached diagram) implements a hub-and-spoke network model on top of AWS Control Tower:

1. **Migration to AWS**: The customer's on-premises workloads are migrated into workload accounts organized under Dev, Test, and Prod OUs. Control Tower Account Factory provisions each workload account with consistent baselines. LZA VPC templates automatically deploy standardized networking (App and Data subnets across 2 AZs, TGW attachments, gateway endpoints) for every new account.

2. **Networking**: AWS Transit Gateway serves as the central hub connecting:
   - Ingress VPC (Perimeter account) — internet-facing load balancers
   - Egress VPC (Perimeter account) — NAT Gateways for outbound internet
   - Inspection VPC (Network account) — AWS Network Firewall for N-S and E-W traffic inspection
   - Endpoints VPC (Network account) — centralized VPC interface endpoints
   - SharedServices VPC — shared organizational services
   - Workload VPCs (Dev/Test/Prod) — application workloads
   
   TGW route tables enforce traffic flow: spoke traffic → Inspection VPC (Network Firewall) → Egress VPC (NAT Gateway) → Internet. IPAM manages IP allocation from a 10.0.0.0/8 pool with hierarchical regional and per-environment pools.

3. **Management and Governance**: Control Tower provides baseline guardrails. LZA extends governance with:
   - 8 custom SCPs (core guardrails, security guardrails, infrastructure guardrails, workload guardrails, sandbox guardrails, suspended guardrails, quarantine)
   - Resource Control Policies (RCPs) for data perimeter enforcement
   - Declarative policies for VPC Block Public Access
   - 12+ Control Tower controls for detective guardrails
   - 30+ AWS Config rules with automated remediation
   - Tagging policies and backup policies enforced at the OU level
   - Quarantine SCP automatically applied to new accounts until LZA pipeline completes

**Why This Deployment Pattern Was Chosen:**
The customer needed a secure, production-ready AWS environment to receive migrated workloads. The hub-and-spoke model was chosen because:
- Centralized network inspection provides consistent security posture across all workloads
- Separation of ingress/egress/inspection into dedicated VPCs follows defense-in-depth principles
- VPC templates enable rapid, consistent provisioning of new workload accounts as migration progresses
- The pattern scales from initial migration through steady-state operations without architectural changes

### Customer Reference #2 (IRSI)
**Met?** Yes

**Partner Response:**
Same deployment pattern: **Migration to AWS** + **Networking** + **Management and Governance**. The customer's migration followed the identical hub-and-spoke architecture with Control Tower governance. The pattern was chosen for the same reasons: centralized inspection, scalable account provisioning, and consistent security guardrails. See attached architecture diagram.

---

## CT-003 — Mandatory Customization Patterns (CfCT, AFT, or LZA)

### Customer Reference #1 (Borinquen)
**Met?** Yes

**Partner Response:**
The solution uses **Landing Zone Accelerator (LZA)** as the customization layer on top of AWS Control Tower, built from the [LZA GitHub repository](https://github.com/awslabs/landing-zone-accelerator-on-aws).

**LZA Version:** v1.14.1 (Universal Configuration v1.1.0)

**Configuration Artifacts:**
The complete LZA configuration is provided as evidence, consisting of:

- **accounts-config.yaml** — Defines mandatory accounts (Management, LogArchive, Audit) and workload accounts (SharedServices, Network, Perimeter)
- **organization-config.yaml** — Defines OU structure, SCPs (8 policies), RCPs, declarative policies, tagging policies, and backup policies
- **network-config.yaml** — Defines Transit Gateway, IPAM pools, VPCs (Ingress, Egress, Inspection, Endpoints, SharedServices), VPC templates (Dev/Test/Prod), Network Firewall, VPC endpoints, and flow logs
- **security-config.yaml** — Defines Security Hub standards (FSBP, NIST 800-53 Rev 5, CIS v3.0.0), GuardDuty, Macie, Config rules (30+), SSM automation documents, IAM password policy, and Access Analyzer
- **global-config.yaml** — Defines Control Tower configuration (LZ v4.0), Control Tower controls (12+), CloudTrail, logging, budgets, CUR, SNS topics, and backup vaults
- **iam-config.yaml** — Defines Identity Center delegation, IAM policies, roles (Backup role, EC2 SSM role), and instance profiles
- **replacements-config.yaml** — Parameterized values for CIDR ranges, email addresses, regions, and subnet masks

**Supporting Policy Files:**
- 8 SCP JSON files in `service-control-policies/`
- 1 RCP JSON file in `rcp-policies/`
- 1 Declarative policy in `declarative-policies/`
- VPC endpoint policies, backup plans, tagging policies, firewall rules, SSM documents, and IAM policies

All configuration files are version-controlled and deployed through the LZA CodePipeline, ensuring repeatable, auditable infrastructure deployments.

### Customer Reference #2 (IRSI)
**Met?** Yes

**Partner Response:**
Same LZA customization. The identical LZA configuration repository (with customer-specific parameter values in `replacements-config.yaml`) was used. All configuration artifacts listed above apply to this customer reference as well.
