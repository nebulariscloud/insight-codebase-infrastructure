# Standard Operating Procedure: Security Engagement
# AWS Account Governance and Identity & Access Management

| Field | Value |
|---|---|
| Document ID | SOP-001 |
| Version | 1.0 |
| Classification | Internal — Partner Confidential |
| Effective Date | [DATE] |
| Last Reviewed | [DATE] |
| Owner | Cloud Security Team |
| Approved By | [NAME], Chief Technology Officer |

---

## 1. Purpose

This document establishes the standard operating procedures for creating and securing AWS accounts on behalf of customers, and for managing identity and access across customer-owned AWS environments. It applies to all customer engagements where the partner provisions, configures, or administers AWS accounts.

These procedures satisfy the requirements defined in the AWS Partner Network (APN) Service Delivery Program for AWS Control Tower, specifically ACCT-001 (Secure AWS Account Governance) and ACCT-002 (Identity Security Best Practices).

---

## 2. Scope

This SOP applies to:

- All engineers, architects, and consultants who create or access customer AWS accounts.
- All customer engagements involving AWS account provisioning, migration, or ongoing managed services.
- Both greenfield deployments and brownfield environments being transitioned to AWS Control Tower.

---

## 3. References

- AWS Well-Architected Framework — Security Pillar
- CIS AWS Foundations Benchmark v3.0.0
- NIST SP 800-53 Rev. 5 — Access Control (AC) and Identification & Authentication (IA) families
- AWS Control Tower Documentation
- Landing Zone Accelerator on AWS Documentation

---

## 4. AWS Account Governance

### 4.1 Account Creation Process

All AWS accounts are provisioned through AWS Control Tower Account Factory. Manual account creation through the AWS Organizations console or the AWS account sign-up page is prohibited.

**Procedure:**

1. A request for a new AWS account is submitted through the internal ticketing system, specifying:
   - Account purpose and owning business unit
   - Target Organizational Unit (OU)
   - Required environment classification (Dev, Test, Prod, Sandbox)
   - Budget owner and cost center
2. The Cloud Engineering team validates the request against the approved OU structure.
3. The account is provisioned via Control Tower Account Factory using a dedicated corporate email alias (e.g., `aws-[account-purpose]@[company-domain].com`).
4. Upon creation, the Landing Zone Accelerator (LZA) quarantine Service Control Policy (SCP) is automatically applied to the account, preventing any user activity until the LZA pipeline completes its configuration run.
5. The LZA pipeline executes, deploying:
   - VPC networking (via VPC templates matched to the target OU)
   - Security baselines (AWS Config rules, Security Hub standards, GuardDuty enrollment)
   - IAM roles and policies (Backup role, EC2 SSM role with instance profile)
   - Tagging policies and backup policies
6. Upon successful pipeline completion, the quarantine SCP is removed and the account is released for use.
7. The account creation is logged in the internal asset register with the account ID, alias, OU, and creation date.

### 4.2 Root Account Usage Policy

The root user of any AWS account must never be used for day-to-day operational or workload activities.

**Controls:**

- AWS Control Tower Central Root User Management is enabled with `rootCredentialsManagement` and `allowRootSessions` capabilities, centralizing root credential lifecycle management.
- Service Control Policies (`lza-core-guardrails-2`) explicitly deny the use of the root user in all member accounts for service-level actions.
- Root user access is restricted to account-level operations that cannot be performed by any other principal, such as:
  - Changing the account's root email address
  - Modifying account-level support plans
  - Closing the AWS account
- All root user activity is logged via AWS CloudTrail and triggers a SecurityHigh SNS alert.

### 4.3 Multi-Factor Authentication on Root

MFA is mandatory on the root user of every AWS account.

**Controls:**

- AWS Control Tower enforces MFA on the management account root user during landing zone setup.
- Security Hub standards (CIS AWS Foundations Benchmark v3.0.0, AWS Foundational Security Best Practices) continuously evaluate whether root MFA is enabled and generate CRITICAL findings if it is not.
- Hardware MFA tokens are preferred for the management account root user. Virtual MFA (e.g., authenticator app) is acceptable for member account root users.
- MFA device registration is performed immediately upon account creation and documented in the secure credential vault.

### 4.4 Account Contact Information

All AWS accounts must be registered with corporate contact information.

**Requirements:**

- The account email address must be a corporate email alias monitored by the operations team (not a personal email address).
- The account phone number must be a corporate phone number reachable during business hours.
- Alternate contacts (Billing, Operations, Security) must be configured with team distribution lists.
- Contact information is set during Account Factory provisioning and validated quarterly.

### 4.5 CloudTrail Logging

AWS CloudTrail must be enabled in all regions for every account, and logs must be protected from accidental or malicious deletion.

**Controls:**

- AWS Control Tower enables an organization-wide CloudTrail trail that captures management events across all regions and all accounts.
- CloudTrail logs are delivered to a dedicated S3 bucket in the LogArchive account, which is a separate account from all workload and administrative accounts.
- The LogArchive account is protected by dedicated SCPs (`lza-core-security-guardrails-1`) that prevent unauthorized modifications to logging resources.
- S3 bucket versioning is enabled on the log bucket.
- S3 lifecycle policies manage log retention: 365-day transition to S3 Glacier Instant Retrieval, 1000-day expiration.
- AWS Config rule `cloudtrail-security-trail-enabled` continuously validates that a security trail is active.
- AWS Config rule `cloudtrail-enabled` validates CloudTrail is enabled in all accounts.
- SCP `lza-core-guardrails-1` prevents unauthorized modifications to CloudTrail configuration.

---

## 5. Identity and Access Management

### 5.1 AWS Management Console and Programmatic Access

All human access to customer AWS accounts is performed through AWS IAM Identity Center.

**Procedure:**

- IAM Identity Center is enabled in the AWS Control Tower configuration and delegated to the SharedServices account for administration.
- Users authenticate through Identity Center, which supports federation with the customer's existing enterprise identity provider (e.g., Microsoft Entra ID, Okta, Active Directory).
- Upon successful authentication, Identity Center issues temporary credentials (STS tokens) for both:
  - AWS Management Console access (browser-based SSO portal)
  - Programmatic access via the AWS CLI v2 (`aws sso login`) or SDKs
- Long-lived IAM access keys are prohibited. No IAM users with console passwords or access keys are created in member accounts.
- Session duration is configured according to the principle of least duration, typically 1–4 hours depending on the permission set.

### 5.2 Temporary Credentials and IAM Roles

All cross-account and service-to-service access uses IAM roles with temporary credentials.

**Requirements:**

- Cross-account access is performed exclusively via `sts:AssumeRole` with temporary session tokens.
- The LZA management account access role (`AWSControlTowerExecution`) is used only by the LZA pipeline for infrastructure orchestration and is protected by SCPs.
- EC2 instances are assigned instance profiles (`EC2-Default-SSM-Role`) with AWS Systems Manager managed policies, eliminating the need for embedded credentials.
- Lambda functions, ECS tasks, and other compute services use execution roles with scoped permissions.
- IAM roles for AWS Backup (`lza-Backup-Role`) assume only the `backup.amazonaws.com` service principal with AWS-managed backup policies.

### 5.3 Enterprise Identity Federation

Customer environments leverage existing enterprise identities through federation.

**Procedure:**

1. During the engagement kickoff, the customer's identity provider (IdP) is identified and documented.
2. IAM Identity Center is configured to federate with the customer's IdP using SAML 2.0 or SCIM provisioning.
3. Permission sets are created in Identity Center, mapping enterprise groups to AWS roles:
   - **AdministratorAccess** — restricted to a small number of named cloud administrators
   - **ReadOnlyAccess** — for auditors and compliance reviewers
   - **PowerUserAccess** — for developers in non-production accounts only
   - **Custom permission sets** — scoped to specific services and actions as required
4. Permission set assignments are documented and reviewed quarterly.
5. If the customer does not have an existing IdP, AWS Managed Microsoft AD or the Identity Center built-in directory is configured as an interim solution, with a migration path to the customer's future IdP.

### 5.4 Least Privilege Enforcement

All IAM principals are granted only the minimum privileges necessary to perform their function.

**Controls:**

- Service Control Policies (SCPs) enforce organizational guardrails:
  - `lza-core-guardrails-1` and `lza-core-guardrails-2` restrict modifications to security services across all OUs
  - `lza-core-security-guardrails-1` restricts networking and storage modifications in Security accounts
  - `lza-infrastructure-guardrails-1` restricts modifications in Infrastructure accounts
  - `lza-core-workloads-guardrails-1` restricts modifications in Workload accounts
  - `lza-core-sandbox-guardrails-1` provides relaxed but bounded permissions for Sandbox accounts
- Resource Control Policies (RCPs) enforce data perimeter controls, preventing unauthorized external access to resources.
- IAM permission boundaries (`lza-End-User-Policy`) are applied to user-created roles, capping the maximum permissions any role can obtain.
- Wildcard (`*`) usage in IAM policy Action and Resource elements is prohibited in customer-managed policies. All policies are reviewed for overly broad permissions before deployment.
- AWS Config rules continuously monitor for policy violations:
  - `iam-no-inline-policy-check` — detects inline policies on users, roles, and groups
  - `iam-user-group-membership-check` — ensures users belong to at least one group
  - `iam-group-has-users-check` — detects empty IAM groups
- IAM Access Analyzer is enabled organization-wide to identify resources shared with external principals and overly permissive policies.

### 5.5 Dedicated Credentials

Every individual who accesses an AWS account must use dedicated, personally identifiable credentials.

**Requirements:**

- Each team member is provisioned with a unique Identity Center user profile linked to their corporate identity.
- Shared accounts, shared credentials, and generic logins (e.g., "admin@company.com") are strictly prohibited.
- All authentication events are logged in CloudTrail with the individual's Identity Center user ID, enabling full auditability.
- Service accounts (for CI/CD pipelines, automation) use dedicated IAM roles with scoped permissions, not shared human credentials.
- Credential usage is reviewed quarterly as part of the access review process.

---

## 6. Compliance Validation

The following automated controls continuously validate adherence to this SOP:

| Control | Service | Scope |
|---|---|---|
| Root MFA enabled | Security Hub (CIS v3.0.0, FSBP) | All accounts |
| No root user activity | SCP `lza-core-guardrails-2` | Member accounts |
| CloudTrail enabled all regions | AWS Config | All accounts |
| CloudTrail log integrity | SCP `lza-core-guardrails-1` | All accounts |
| No inline IAM policies | AWS Config + Control Tower control | All accounts |
| IAM users in groups | AWS Config + Control Tower control | All accounts |
| Security Hub enabled | AWS Config + Control Tower control | All accounts |
| IAM Access Analyzer active | Security Config | All accounts |
| No long-lived access keys | Security Hub (CIS v3.0.0) | All accounts |

---

## 7. Revision History

| Version | Date | Author | Description |
|---|---|---|---|
| 1.0 | [DATE] | [AUTHOR] | Initial release |
