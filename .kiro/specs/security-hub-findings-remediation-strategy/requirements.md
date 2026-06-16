# Requirements Document

## Introduction

This feature delivers a **Remediation Strategy Document** (and its supporting governance artifacts) that defines how Security Hub CSPM findings are systematically resolved across the AWS Organization built on Landing Zone Accelerator (LZA).

The immediate driver is a CSPM report for the PCI account (`247514667218`) showing 57 failing findings across CIS AWS Foundations Benchmark v3.0.0, NIST 800-53 r5, AWS Foundational Security Best Practices v1.0.0, and PCI DSS v4.0.1, spanning regions `us-east-1`, `us-east-2`, and `us-west-2`. However, the deliverable is **not** a one-off PCI fix list. It is a reusable strategy that:

1. Classifies each finding by the most appropriate remediation mechanism (LZA configuration, AWS Config Rule + SSM Automation, Terraform / one-shot script, manual human action, or deferred).
2. Produces a prioritization framework based on severity, blast radius, and ease of automation.
3. Defines a phased rollout that begins with the PCI account and extends to every spoke account in the organization.
4. Captures decision-pending items, permission gaps, and prerequisites (e.g., root + MFA, bucket recreation, owner approvals) so they are tracked and not lost.
5. Establishes a repeatable categorization rubric so future findings (in PCI or any other account) can be triaged with the same criteria.

The deliverable is a living governance document, reviewable by the security owner, that drives later implementation work in separate specs (LZA config edits, Config Rules, Terraform modules, etc.).

## Glossary

- **Remediation_Strategy**: The markdown strategy document (`strategy.md` or equivalent) and its supporting artifacts (disposition table, prioritization matrix, rollout plan) produced by this feature.
- **Finding**: A single Security Hub control failure identified by its control ID (e.g., `SSM.7`, `S3.20`, `EC2.10`) in a specific account and region.
- **Control_Family**: The originating standard for a Finding, such as `CIS_AWS_Foundations_Benchmark_v3.0.0`, `NIST_800-53_r5`, `AWS_FSBP_v1.0.0`, or `PCI_DSS_v4.0.1`.
- **LZA**: AWS Landing Zone Accelerator, the IaC framework that owns `aws-accelerator-config/` (including `global-config.yaml`, `security-config.yaml`, `network-config.yaml`, `iam-config.yaml`, `organization-config.yaml`).
- **Hub_Account**: The Management, Audit, LogArchive, Network, Perimeter, or SharedServices account.
- **Spoke_Account**: A non-hub workload account (PCI is a Spoke_Account in this org).
- **Active_Region**: One of `us-east-1`, `us-east-2`, `us-west-2`.
- **Remediation_Mechanism**: One of the following five categories:
  - `LZA-Config` — fix is expressed declaratively in an LZA config file and deployed organization-wide.
  - `Config-Rule-SSM` — AWS Config managed/custom rule with an SSM Automation document for auto-remediation.
  - `Terraform` — point-in-time fix delivered via the `terraform/` tooling in this workspace (or a one-shot script) for resources outside LZA's declarative surface.
  - `Manual` — requires a human action that cannot be automated (e.g., root user + MFA for S3 MFA Delete, bucket recreation with data migration).
  - `Deferred` — blocked pending a decision from Alex, a permission grant, or an external prerequisite.
- **Disposition_Table**: A per-finding row that assigns control ID, severity, standard, recommended Remediation_Mechanism, owner, prerequisites, target Rollout_Wave, and scaling note.
- **Prioritization_Framework**: A documented scoring model combining severity, blast radius, and ease-of-automation that produces an ordered execution sequence.
- **Rollout_Wave**: A named, ordered phase (Wave 1, Wave 2, …) that scopes which findings, accounts, and regions are addressed together.
- **Blast_Radius**: The number of accounts and regions impacted by a Finding or by its remediation.
- **Decision_Pending_Item**: A Finding whose disposition cannot be finalized until a documented owner decision is made (e.g., Inspector activation per region, CloudFormation termination protection scope, CloudTrail data events scope, Lambda VPC placement).
- **Permission_Gap**: A Finding that cannot currently be assessed or remediated because the operator lacks the required IAM permissions (e.g., `iam:ListPolicies` access denied).
- **Prerequisite**: A precondition that must be satisfied before a Finding can be remediated (e.g., root + MFA, bucket recreation, data migration, owner approval).
- **Org_Wide_Preventive_Control**: A control implemented through LZA, SCPs, RCPs, declarative policies, or Control Tower controls so the failure cannot recur in any account in scope.
- **Detective_Corrective_Pair**: An AWS Config Rule (detective) paired with an SSM Automation document (corrective) that auto-remediates non-compliant resources.

## Requirements

### Requirement 1: Finding Inventory and Source-of-Truth

**User Story:** As the security owner, I want every Security Hub finding from the source CSPM report captured in a single inventory inside the strategy document, so that no finding is silently dropped during triage.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a Finding inventory section that lists every Finding from the source CSPM report.
2. THE Remediation_Strategy SHALL record, for each Finding, the control ID, control title, severity, originating Control_Family, affected account, and affected Active_Region.
3. WHEN a single control ID appears multiple times across resources, accounts, or regions, THE Remediation_Strategy SHALL group the occurrences under a single inventory entry and enumerate the distinct resource scopes.
4. THE Remediation_Strategy SHALL cite the source CSPM report file name and snapshot date used to populate the inventory.
5. IF a Finding from the source report lacks sufficient information to classify (e.g., due to a Permission_Gap), THEN THE Remediation_Strategy SHALL still list the Finding and mark its Remediation_Mechanism as `Deferred` with a documented reason.

### Requirement 2: Remediation Mechanism Categorization Rubric

**User Story:** As an engineer planning a fix, I want a documented rubric that tells me which Remediation_Mechanism fits each Finding, so that mechanism choice is consistent and auditable instead of ad hoc.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL define exactly five Remediation_Mechanism categories: `LZA-Config`, `Config-Rule-SSM`, `Terraform`, `Manual`, and `Deferred`.
2. THE Remediation_Strategy SHALL define, for each Remediation_Mechanism, the decision criteria that qualify a Finding for that mechanism, expressed as a checklist a reviewer can apply.
3. THE Remediation_Strategy SHALL prefer `LZA-Config` when the fix is a declarative organization-wide control already supported by an LZA config file (`global-config.yaml`, `security-config.yaml`, `network-config.yaml`, `iam-config.yaml`, `organization-config.yaml`, `customizations-config.yaml`).
4. THE Remediation_Strategy SHALL prefer `Config-Rule-SSM` when the Finding requires per-resource detection plus corrective action and an AWS Config managed rule plus SSM Automation document can express the fix.
5. THE Remediation_Strategy SHALL prefer `Terraform` when the fix targets resources outside LZA's declarative surface or requires a point-in-time change that does not need ongoing enforcement.
6. THE Remediation_Strategy SHALL classify a Finding as `Manual` only when no automated mechanism can perform the fix (for example, S3 MFA Delete requiring root + MFA, or bucket recreation with data migration for S3 Object Lock).
7. THE Remediation_Strategy SHALL classify a Finding as `Deferred` only when a Decision_Pending_Item, Permission_Gap, or external Prerequisite blocks disposition.
8. WHEN two mechanisms could both fix a Finding, THE Remediation_Strategy SHALL apply a documented tie-breaker rule that prefers the mechanism with the broadest org-wide preventive coverage.
9. THE Remediation_Strategy SHALL reference, for each `LZA-Config` disposition, the specific LZA config file and section expected to carry the change.
10. THE Remediation_Strategy SHALL reference, for each `Config-Rule-SSM` disposition, the AWS managed Config rule identifier and the SSM Automation document name (existing or new) expected to perform remediation.

### Requirement 3: Per-Finding Disposition Table

**User Story:** As the security owner, I want a single table that gives every Finding a recommended mechanism, owner, prerequisites, and rollout wave, so that the strategy is directly executable and reviewable in one place.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a Disposition_Table that contains one row per Finding inventory entry from Requirement 1.
2. THE Disposition_Table SHALL include the following columns for each row: control ID, severity, Control_Family, recommended Remediation_Mechanism, target artifact reference, owner, Prerequisite list, Rollout_Wave, and scaling note.
3. THE Remediation_Strategy SHALL assign exactly one Remediation_Mechanism per row.
4. WHEN a Finding has unresolved Prerequisites, THE Disposition_Table SHALL list each Prerequisite explicitly in the Prerequisite column.
5. WHEN a Finding is a Decision_Pending_Item, THE Disposition_Table SHALL identify the owner of the pending decision and the specific question awaiting an answer.
6. WHEN a Finding has a Permission_Gap, THE Disposition_Table SHALL identify the missing permission and the principal or role that needs the grant.

### Requirement 4: Prioritization Framework

**User Story:** As the security owner, I want a documented scoring model that orders findings by severity, blast radius, and ease of automation, so that the team works the highest-value items first.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL define a Prioritization_Framework that combines three explicit factors: severity, Blast_Radius, and ease of automation.
2. THE Prioritization_Framework SHALL define a numeric or ordinal scale for each factor with documented values (for example, severity mapped to Critical, High, Medium, Low; Blast_Radius mapped to single-resource, single-account-multi-region, multi-account-multi-region; ease-of-automation mapped to Trivial, Moderate, Hard, Manual-only).
3. THE Prioritization_Framework SHALL define an aggregation rule that produces a single priority score per Finding.
4. THE Remediation_Strategy SHALL apply the Prioritization_Framework to every row in the Disposition_Table and record the resulting score.
5. THE Remediation_Strategy SHALL produce an ordered execution sequence of Findings derived from the priority scores.
6. WHEN two Findings have identical priority scores, THE Remediation_Strategy SHALL apply a documented tie-breaker that favors the Finding with the larger Blast_Radius.

### Requirement 5: Severity and Standard Coverage

**User Story:** As an auditor, I want the strategy to demonstrate coverage across all severity levels and all in-scope compliance standards, so that I can verify the plan is complete.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a coverage summary that counts Findings by severity (Critical, High, Medium, Low).
2. THE Remediation_Strategy SHALL include a coverage summary that counts Findings by Control_Family.
3. THE Remediation_Strategy SHALL include a coverage summary that counts Findings by recommended Remediation_Mechanism.
4. WHEN a severity level has zero Findings, THE Remediation_Strategy SHALL state the zero count explicitly rather than omitting the level.

### Requirement 6: Org-Wide Scaling Considerations

**User Story:** As a platform owner, I want the strategy to be forward-looking and reusable for every spoke account, so that fixes applied to PCI also benefit other accounts without re-doing the analysis.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL identify, for each row in the Disposition_Table, whether the Finding is account-specific or expected to recur across multiple accounts.
2. WHEN a Finding is expected to recur across accounts, THE Remediation_Strategy SHALL prefer an Org_Wide_Preventive_Control disposition over a per-account fix.
3. THE Remediation_Strategy SHALL list the spoke accounts and Active_Regions that are in scope for the strategy.
4. THE Remediation_Strategy SHALL describe how each `LZA-Config` and `Config-Rule-SSM` disposition propagates to other accounts (for example, by referencing the LZA `deploymentTargets` mechanism).
5. THE Remediation_Strategy SHALL describe how account-scoped fixes (e.g., `Terraform` or `Manual`) are tracked and replayed when a new account is onboarded.

### Requirement 7: Rollout Plan and Waves

**User Story:** As the engineer executing the strategy, I want a phased rollout plan that starts with the PCI account and extends to other spokes, so that risk is contained and each phase has a clear definition of done.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL define an ordered set of Rollout_Waves with named scope, target accounts, target regions, and entry/exit criteria for each wave.
2. THE Remediation_Strategy SHALL designate the PCI account (`247514667218`) as the first-wave target.
3. THE Remediation_Strategy SHALL define a subsequent wave or waves that extend remediation to all other spoke accounts in the organization.
4. THE Remediation_Strategy SHALL assign every row in the Disposition_Table to exactly one Rollout_Wave.
5. THE Remediation_Strategy SHALL document, for each Rollout_Wave, the rollback approach if a remediation introduces a regression.
6. THE Remediation_Strategy SHALL document, for each Rollout_Wave, the validation method used to confirm Findings are resolved (for example, Security Hub re-scan, AWS Config compliance state, manual evidence capture).

### Requirement 8: Decision-Pending Items Register

**User Story:** As the security owner, I want every blocked decision tracked in one register with the question, options, and decision owner, so that pending decisions are visible and actionable.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a Decision_Pending_Items register.
2. THE Decision_Pending_Items register SHALL list, for each item, the related Finding control ID, the specific question, the available options with tradeoffs, the decision owner, and the impact of delay.
3. THE Remediation_Strategy SHALL include entries in the Decision_Pending_Items register for at least the following known items: Inspector activation per region, CloudFormation termination protection scope, CloudTrail data events scope, and Lambda VPC placement.
4. WHEN a Decision_Pending_Item is resolved, THE Remediation_Strategy SHALL describe how the decision feeds back into the Disposition_Table and Rollout_Waves.

### Requirement 9: Permission Gaps and Manual Prerequisites Register

**User Story:** As the operator, I want a register of permission gaps and manual prerequisites (root + MFA, bucket recreation, data migration), so that blockers are surfaced early instead of discovered mid-remediation.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a Permission_Gaps_And_Prerequisites register.
2. THE Permission_Gaps_And_Prerequisites register SHALL list, for each entry, the related Finding control ID, the missing permission or required prerequisite, the principal or role responsible, and the resolution path.
3. THE Remediation_Strategy SHALL include entries for at least the following known prerequisites: S3 MFA Delete (root + MFA), S3 Object Lock (bucket recreation plus data migration), and `iam:ListPolicies` access denied.
4. WHEN a Permission_Gap is resolved or a Prerequisite is satisfied, THE Remediation_Strategy SHALL describe how the affected Finding is moved out of `Deferred` status.

### Requirement 10: Validation, Verification, and Drift Detection

**User Story:** As the security owner, I want the strategy to specify how each fix is verified and how regressions are detected, so that compliance is sustained and not just achieved once.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL define, for each Remediation_Mechanism, a verification approach that confirms a Finding is resolved.
2. THE Remediation_Strategy SHALL define a re-scan cadence (for example, post-LZA-pipeline run, scheduled Security Hub aggregation) used to confirm that resolved Findings remain resolved.
3. WHEN a `Config-Rule-SSM` disposition is selected, THE Remediation_Strategy SHALL identify how AWS Config compliance state is monitored and how non-compliant resources trigger remediation.
4. WHEN an `LZA-Config` disposition is selected, THE Remediation_Strategy SHALL identify how the change is validated after the next LZA pipeline run (for example, by reviewing CloudFormation stack outputs or Security Hub re-scan).
5. THE Remediation_Strategy SHALL describe a drift-detection approach that flags Findings re-appearing after remediation.

### Requirement 11: Document Structure and Maintainability

**User Story:** As a future contributor, I want the strategy document to follow a predictable structure with versioning, owners, and review cadence, so that the document stays current as new findings appear.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL be authored as one or more markdown files under `.kiro/specs/security-hub-findings-remediation-strategy/`.
2. THE Remediation_Strategy SHALL include a top-level metadata block that records document version, last review date, document owner, and source CSPM report reference.
3. THE Remediation_Strategy SHALL include a table of contents covering each major section: Introduction, Glossary, Inventory, Categorization Rubric, Disposition Table, Prioritization Framework, Coverage Summary, Org-Wide Scaling, Rollout Plan, Decision_Pending_Items register, Permission_Gaps_And_Prerequisites register, Validation, and Maintenance.
4. THE Remediation_Strategy SHALL define a review cadence and a re-evaluation trigger (for example, on each new Security Hub aggregation, on each new account onboarding).
5. WHEN a new Finding appears that is not in the inventory, THE Remediation_Strategy SHALL describe the procedure for adding the Finding to the inventory and Disposition_Table using the Categorization Rubric and Prioritization_Framework.

### Requirement 12: Explicit Disposition for the 57 Known Findings

**User Story:** As the security owner, I want the strategy to explicitly cover the 57 known PCI findings reported by the source CSPM, so that the immediate compliance gap is fully addressed.

#### Acceptance Criteria

1. THE Remediation_Strategy SHALL include a Disposition_Table row for each of the following control IDs from the source CSPM report: `SSM.7`, `IAM.28`, `EC2.182`, `Inspector.1`, `Inspector.2`, `Inspector.3`, `Inspector.4`, `Account.1`, `S3.5`, `S3.9`, `S3.10`, `S3.11`, `S3.15`, `S3.17`, `S3.22`, `S3.23`, `CloudWatch.16`, `SNS.1`, `KMS.1`, `EC2.10`, `EC2.55`, `EC2.56`, `EC2.57`, `EC2.58`, `EC2.60`, `CloudFormation.3`, `CloudFormation.4`, `SSM.6`, `IAM.18`, `IAM.21`, `S3.7`, `S3.13`, `S3.20`, `Lambda.3`, and `Lambda.7`.
2. THE Disposition_Table SHALL classify `SSM.7` (block public sharing of SSM documents) with a recommended Remediation_Mechanism and target artifact reference.
3. THE Disposition_Table SHALL classify the Inspector activation Findings (`Inspector.1`, `Inspector.2`, `Inspector.3`, `Inspector.4`) and link them to a Decision_Pending_Item covering per-region activation scope.
4. THE Disposition_Table SHALL classify `S3.20` (MFA Delete) as `Manual` and link it to the Permission_Gaps_And_Prerequisites register entry for root + MFA.
5. THE Disposition_Table SHALL classify `S3.15` (Object Lock) with a Prerequisite that captures the bucket-recreation and data-migration constraint.
6. THE Disposition_Table SHALL group duplicate Findings (for example, the same S3 control failing on multiple buckets, or the same EC2 VPC endpoint control failing in multiple regions) under a single inventory entry per Requirement 1, while still enumerating each affected resource scope in the Disposition_Table row.
