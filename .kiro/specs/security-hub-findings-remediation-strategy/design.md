# Design Document — Security Hub Findings Remediation Strategy

## Metadata

| Field | Value |
|---|---|
| Document version | 1.0 |
| Last review | 2026-06-15 |
| Document owner | Cloud Platform / Security |
| Source CSPM report | `Findings Security Hub CSPM - PCI - Summary.csv` |
| In-scope account (Wave 1) | PCI account `247514667218` |
| In-scope regions | `us-east-1`, `us-east-2`, `us-west-2` |
| Compliance standards | CIS AWS Foundations v3.0.0, NIST 800-53 r5, AWS FSBP v1.0.0, PCI DSS v4.0.1 |
| Headline state | 774 controls passed, 57 failed, 92% compliance |

## Overview

This document is a **strategy** for resolving every Security Hub finding in a way that fits the Landing Zone Accelerator (LZA) hub-and-spoke architecture and prevents recurrence on every other spoke account, present and future. It is not an implementation plan. It is the design that drives separate implementation specs (one per mechanism family).

The immediate trigger is a CSPM snapshot for the PCI account showing 57 failures across CIS AWS Foundations v3.0.0, NIST 800-53 r5, AWS FSBP v1.0.0, and PCI DSS v4.0.1. The strategy addresses those 57 findings explicitly and also defines a reusable rubric so any future finding (in PCI or any other account) is triaged with the same criteria.

**Goals.**

- Resolve all 57 known PCI findings.
- Prevent recurrence org-wide by preferring the broadest preventive mechanism each finding allows.
- Pick the right mechanism per finding instead of forcing one tool on the whole list.
- Surface every blocker (decisions, permissions, manual prerequisites) so nothing silently stalls.

**Non-goals.**

- This document does not replace AWS Control Tower or LZA controls already in place. It layers on top of them.
- It does not implement fixes. It defines the design that drives separate implementation specs.
- It does not change Security Hub standards selection. The four enabled standards stay enabled.

**Mental model — why one mechanism doesn't fit all.**

A natural first instinct for 57 findings is "use AWS Config rules with auto-remediation." That works for resource-level controls (S3 buckets, SNS topics, log groups) but fails for the rest of the list:

- **Account/region service settings** (Inspector enablement, EBS snapshot block public access, SSM document public sharing, SSM Automation CW logging) are not resource-level configurations. AWS Config does not evaluate them as resource compliance state.
- **Org-wide preventive controls** (security contact, support role, password policy, GuardDuty/Macie/Security Hub enablement) are best expressed declaratively in LZA so a new account inherits them on day one rather than relying on detective rules to catch the gap after creation.
- **Manual-only controls** (S3 MFA Delete, S3 Object Lock on existing buckets) cannot be remediated by Config rules — AWS requires root + MFA, or the bucket needs to be recreated.
- **Decisions, not technical fixes** (Lambda VPC placement on LZA-managed functions, CloudFormation termination protection on LZA-managed stacks) need a documented decision before any tool can apply them.

So the right answer is a **layered strategy**: prefer the mechanism with the largest preventive footprint, fall through to detective + corrective, then point-in-time fixes, then manual, with deferred entries tracked explicitly.

## Architecture

### Layered remediation pipeline

```
                       ┌──────────────────────────────────────────────┐
Preventive (broadest)  │  1. LZA-Config (declarative, org-wide)       │
                       └──────────────────────────────────────────────┘
                                          │  not expressible in LZA
                                          ▼
                       ┌──────────────────────────────────────────────┐
Detective + corrective │  2. Config Rule + SSM Automation             │
                       └──────────────────────────────────────────────┘
                                          │  not a resource-level control
                                          ▼
                       ┌──────────────────────────────────────────────┐
Point-in-time          │  3. Terraform / one-shot script              │
                       └──────────────────────────────────────────────┘
                                          │  cannot be automated
                                          ▼
                       ┌──────────────────────────────────────────────┐
Human action           │  4. Manual (root + MFA, bucket recreation)   │
                       └──────────────────────────────────────────────┘
                                          │  blocked
                                          ▼
                       ┌──────────────────────────────────────────────┐
Tracked & blocked      │  5. Deferred (decision, permission, prereq)  │
                       └──────────────────────────────────────────────┘
```

### Where each layer lives in this repo

| Layer | Implementation surface |
|---|---|
| LZA-Config | `aws-accelerator-config/*.yaml` |
| Config Rule + SSM Automation | `awsConfig.ruleSets` and `ssmAutomation.documentSets` in `security-config.yaml`; new SSM YAMLs under `ssm-documents/`; remediation IAM under `ssm-remediation-roles/` |
| Terraform | new module `terraform/modules/security-baseline/` invoked from `terraform/live/<account>/security-baseline/` |
| Manual | runbook entries appended to `pci-onboarding-guide.md` and a generic `account-onboarding-guide.md` |
| Deferred | the registers in this document |

### Flow of a finding through the pipeline

```
   ┌──────────────────────┐
   │  New Security Hub    │
   │  finding observed    │
   └──────────┬───────────┘
              ▼
   ┌──────────────────────┐
   │ Apply 5-bucket       │     pick first matching layer
   │ rubric (§ Components)│     1 → 2 → 3 → 4 → 5
   └──────────┬───────────┘
              ▼
   ┌──────────────────────┐
   │ Score with priority  │     priority = 3·S + 2·B + 1·E
   │ framework (§ Data)   │
   └──────────┬───────────┘
              ▼
   ┌──────────────────────┐
   │ Assign to wave       │     Wave 1 = PCI; Wave 2 = other spokes;
   │                      │     Wave 3 = deferred backfill
   └──────────┬───────────┘
              ▼
   ┌──────────────────────┐
   │ Implement, validate  │     verification per § Testing Strategy
   │ (separate spec)      │
   └──────────────────────┘
```

### Org-wide propagation

For every `LZA-Config` disposition the deployment target defaults to `Root`. The PCI fix and the org-wide fix are the same change; LZA expands it across every account on the next pipeline run. `Config-Rule-SSM` items follow the same `deploymentTargets: organizationalUnits: [Root]` pattern already used in `security-config.yaml`. `Terraform` items are wired through the account-onboarding runbook so new accounts pick them up.

## Components and Interfaces

### Component 1 — The 5-bucket categorization rubric

Each finding gets exactly one bucket. Walk top to bottom and stop at the first match.

#### Bucket 1: `LZA-Config`

Pick this when **all** of the following are true:

- LZA exposes a primitive that expresses the control (a key in `global-config.yaml`, `security-config.yaml`, `network-config.yaml`, `iam-config.yaml`, `organization-config.yaml`, or `customizations-config.yaml`).
- The control is meaningfully org-wide (you want every account in the OU tree to inherit it).
- The fix is declarative, not a one-shot imperative call.

Why first: LZA propagates via `deploymentTargets`, reverts manual drift on the next pipeline run, and gives a new account the control on day one. Highest-leverage mechanism.

Examples: `IAM.28` (Access Analyzer), `EC2.10/55/56/57/58/60` (interface endpoints), `IAM.18` (support role), `S3.22/23` (CloudTrail data events), `Account.1` (alternate security contact), `CloudWatch.16` (default log retention via `cloudwatchLogRetentionInDays`).

#### Bucket 2: `Config-Rule-SSM`

Pick this when:

- The control is per-resource (per bucket, per topic, per log group, per function).
- An AWS managed Config rule exists, or a custom rule is straightforward.
- An AWS managed SSM Automation document exists for remediation, or a custom one fits the existing `ssmAutomation.documentSets` pattern.
- LZA cannot express the desired state declaratively for the resource type.

This pattern is already wired in `security-config.yaml`. The two existing examples (`ec2-instance-profile-attached`, `elb-logging-enabled`) are the template, with `automatic: true` remediation and `rolePolicyFile` for the SSM IAM.

Examples: `S3.5` SSL only, `S3.9` access logging, `S3.13` lifecycle, `S3.17` KMS, `SNS.1` SNS KMS, `CloudWatch.16` retention (alt path).

#### Bucket 3: `Terraform`

Pick this when:

- The fix is an account or region-level service setting AWS Config does not evaluate (Inspector, EBS snapshot block, SSM document public sharing, SSM Automation CW logging).
- The fix is point-in-time; once set, no ongoing enforcement is needed unless drift is actively reverted by something else.
- LZA does not expose the primitive.

Pattern: a small module under `terraform/modules/security-baseline/`, invoked from `terraform/live/<account>/security-baseline/`, with provider aliases per region and `for_each` over the active regions.

Examples: `SSM.7`, `EC2.182`, `SSM.6`, `Inspector.1-4` (once decisions land), `S3.7` CRR.

#### Bucket 4: `Manual`

Pick this only when no automation can perform the action:

- AWS requires root + MFA (S3 MFA Delete).
- Resource recreation with data migration (S3 Object Lock on existing buckets).
- Real-world activity (typing a verified phone number, signing a document).

Each manual item gets a runbook entry and a compliance-evidence capture step.

#### Bucket 5: `Deferred`

Pick this only when blocked by:

- A pending decision the security or platform owner has not made.
- A permission the operator does not have (e.g., `iam:ListPolicies` denied).
- A prerequisite that has not been satisfied (data migration, contact info collection).

Deferred is a holding state, not a final state. Each entry names an owner and an unblocking action.

#### Tie-breaker

When two buckets could fix a finding, pick the one with the **broadest preventive footprint and lowest ongoing operational cost**. In practice: prefer `LZA-Config` over `Config-Rule-SSM`, prefer `Config-Rule-SSM` over `Terraform`, prefer `Terraform` over `Manual`.

### Component 2 — Source CSPM ingestion contract

| Field | Required | Source column |
|---|---|---|
| Control ID | yes | `ID` |
| Title | yes | `Title` |
| Severity | yes | `Severity` |
| Originating standard | yes | derived from the standard summary |
| Affected account | yes | external context |
| Affected region(s) | yes | parsed from `Reason`/`Comments` |
| Resource scope | yes | parsed from `Reason`/`Solution` |
| Owner notes | optional | `Comments` |

Future CSPM snapshots are dropped into `partner-file/` (existing convention) and trigger a re-run of the rubric for any new control IDs.

### Component 3 — Disposition table interface

Every row produced by the rubric is a tuple consumed by Wave planning:

```
{
  control_id:        string,
  severity:          "Critical" | "High" | "Medium" | "Low",
  standard:          string,
  mechanism:         "LZA-Config" | "Config-Rule-SSM" | "Terraform" | "Manual" | "Deferred",
  target_artifact:   string,    // file path or AWS managed identifier
  scope:             string,    // resource set
  owner:             string,
  prerequisites:     string[],
  priority_score:    integer,
  wave:              1 | 2 | 3
}
```

The full table is in **Data Models — Disposition table**.

### Component 4 — Decision-Pending Items register interface

Every deferred row pointing at a pending decision has an entry here with: related finding(s), question, options with tradeoffs, decision owner, impact of delay. Resolutions feed back into Component 3 by changing `mechanism` from `Deferred` to a real bucket and re-scoring.

### Component 5 — Permission Gaps and Manual Prerequisites register interface

Every deferred row pointing at a missing permission or unsatisfied prerequisite has an entry here with: related finding(s), the gap or prerequisite, the responsible principal, the resolution path.

## Data Models

### Disposition table — full inventory

> Notation: `region-set` means the set of `us-east-1`, `us-east-2`, `us-west-2` where the control is failing. Inventory entries collapse duplicate findings on the same control across resources/regions; the "Scope" column enumerates the affected resource set.

#### Critical

| # | Control | Title | Mechanism | Target artifact | Scope | S/B/E | Priority | Wave |
|---|---|---|---|---|---|---|---|---|
| 1 | `SSM.7` | SSM documents block public sharing | `Terraform` | `terraform/modules/security-baseline/ssm.tf` (`aws_ssm_service_setting`) — **Wave 1 implementation complete** in `terraform/modules/security-baseline/ssm-document-public-sharing.tf`, applied via `terraform/live/pci/security-baseline/` | All 3 regions, account-level | 4/2/4 | 20 | 1 |

#### High

| # | Control | Title | Mechanism | Target artifact | Scope | S/B/E | Priority | Wave |
|---|---|---|---|---|---|---|---|---|
| 2 | `IAM.28` | Access Analyzer external access analyzer enabled | `LZA-Config` | `security-config.yaml` `accessAnalyzer.enable` (LZA already sets `true`; investigate why analyzer not landing in PCI account/regions) | Per-account, per-region | 3/3/4 | 19 | 1 |
| 3 | `EC2.182` | Block public access for EBS snapshots | `Terraform` | `terraform/modules/security-baseline/ebs.tf` (`aws_ebs_snapshot_block_public_access`) — **Wave 1 implementation complete** in `terraform/modules/security-baseline/ebs-snapshot-public-access.tf`, applied via `terraform/live/pci/security-baseline/` | All 3 regions | 3/2/4 | 17 | 1 |
| 4 | `Inspector.1` | Inspector EC2 scanning | `Deferred` → `Terraform` | `terraform/modules/security-baseline/inspector.tf` once D-1 lands | `us-east-1`, `us-west-2` | 3/1/3 | 14 | 2 |
| 5 | `Inspector.2` | Inspector ECR scanning | `Deferred` → `Terraform` | same module | `us-east-1`, `us-west-2` | 3/1/3 | 14 | 2 |
| 6 | `Inspector.3` | Inspector Lambda code scanning | `Deferred` → `Terraform` | same module | `us-east-1`, `us-west-2` | 3/1/3 | 14 | 2 |
| 7 | `Inspector.4` | Inspector Lambda standard scanning | `Deferred` → `Terraform` | same module | `us-east-1`, `us-west-2` | 3/1/3 | 14 | 2 |

#### Medium

| # | Control | Title | Mechanism | Target artifact | Scope | S/B/E | Priority | Wave |
|---|---|---|---|---|---|---|---|---|
| 8 | `Account.1` | Security alternate contact | `Terraform` | `terraform/modules/security-baseline/account-contacts.tf` (`aws_account_alternate_contact`) — **Wave 1 implementation complete**, phone sourced from SharedServices SSM SecureString `/security-baseline/security-contact-phone`. D-7 resolved (see register) | All accounts (3 instances: 8, 16, 31) | 2/3/3 | 15 | 1 (PCI), 2 (others) |
| 9 | `S3.22` | S3 object-level write events in CloudTrail | `Manual` | one-time Console change on Control Tower `BaselineCloudTrail` in Management account; documented in `cloudtrail-data-events-runbook.md` (D-9 resolved option c) | Org-wide | 2/3/3 | 15 | 1 |
| 10 | `S3.23` | S3 object-level read events in CloudTrail | `Manual` | same runbook as #9, ReadOnly selector | Org-wide | 2/3/3 | 15 | 1 |
| 11 | `S3.5` | S3 buckets require SSL | `Config-Rule-SSM` | Config rule `s3-bucket-ssl-requests-only` + SSM `AWSConfigRemediation-RestrictBucketSSLRequestsOnly` | All buckets (findings 11, 27, 40, 46) | 2/3/3 | 15 | 1 |
| 12 | `S3.17` | S3 buckets encrypted with KMS | `Config-Rule-SSM` | Config rule `s3-default-encryption-kms` + SSM `AWS-EnableS3BucketEncryption` (param: KMS key ARN) | All buckets (findings 14, 42) | 2/3/3 | 15 | 1 |
| 13 | `S3.9` | S3 server access logging | `Config-Rule-SSM` | Config rule `s3-bucket-logging-enabled` + SSM `AWS-ConfigureS3BucketLogging` (param: per-region access-log bucket) | All buckets (findings 15, 30, 43) | 2/3/3 | 15 | 1 |
| 14 | `SNS.1` | SNS topic encryption with KMS | `Config-Rule-SSM` | Config rule `sns-encrypted-kms` + SSM `AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic` | All topics, org-wide | 2/3/3 | 15 | 1 |
| 15 | `S3.10` | S3 buckets with versioning have lifecycle | `Config-Rule-SSM` | custom Config rule + SSM doc | All versioned buckets | 2/2/3 | 13 | 1 |
| 16 | `S3.11` | S3 event notifications | `Terraform` per-bucket or `Manual` | `terraform/live/<account>/s3-events/` | Per-bucket where business needs apply | 2/2/2 | 12 | 2 |
| 17 | `CloudWatch.16` | Log group retention configured | `LZA-Config` + `Config-Rule-SSM` | `global-config.yaml` already sets `cloudwatchLogRetentionInDays: 365` for LZA-created groups; add Config rule `cw-loggroup-retention-period-check` + SSM `AWS-UpdateCloudWatchLogGroupRetention` for non-LZA groups | All log groups | 2/3/3 | 15 | 1 |
| 18 | `EC2.10` | VPC interface endpoint for EC2 | `LZA-Config` | `network-config.yaml` `interfaceEndpoints` already includes `ec2`; verify `vpc-0766c6bceb81ea3fa` consumes central endpoints (`useCentralEndpoints: true`) or has its own list | All spoke VPCs | 2/3/4 | 16 | 1 |
| 19 | `EC2.55` | VPC interface endpoint for ECR API | `LZA-Config` | `network-config.yaml` already includes `ecr.api` | Same | 2/3/4 | 16 | 1 |
| 20 | `EC2.56` | VPC interface endpoint for ECR DKR | `LZA-Config` | `network-config.yaml` already includes `ecr.dkr` | Same | 2/3/4 | 16 | 1 |
| 21 | `EC2.57` | VPC interface endpoint for SSM | `LZA-Config` | `network-config.yaml` already includes `ssm` | Same | 2/3/4 | 16 | 1 |
| 22 | `EC2.58` | VPC interface endpoint for SSM Contacts | `LZA-Config` | `network-config.yaml` add `ssm-contacts` (currently commented out) | Same | 2/3/4 | 16 | 1 |
| 23 | `EC2.60` | VPC interface endpoint for SSM Incidents | `LZA-Config` | `network-config.yaml` already includes `ssm-incidents` | Same | 2/3/4 | 16 | 1 |
| 24 | `S3.15` | S3 Object Lock | `Manual` | runbook: recreate empty log buckets with Object Lock; migrate `awsconfigconforms-pci-dss-templates-icc-pr` content | Per-bucket (findings 13, 41) | 2/2/2 | 12 | 2 |
| 25 | `KMS.1` | Customer policies don't allow `kms:*` decrypt on `*` | `Deferred` → `Terraform` | resolve P-1 then policy edits via Terraform on the IAM management surface | Org-wide (findings 19, 33) | 2/3/2 | 14 | 2 |
| 26 | `CloudFormation.4` | Stacks have service roles | `Deferred` | D-4: should LZA-managed stacks inherit a service role? | LZA-managed stacks | 2/3/2 | 14 | 2 |
| 27 | `CloudFormation.3` | Stack termination protection | `Deferred` | D-3: enable on LZA-managed stacks without breaking the pipeline? | LZA-managed stacks | 2/3/2 | 14 | 2 |
| 28 | `SSM.6` | SSM Automation CloudWatch logging | `Terraform` | `terraform/modules/security-baseline/ssm.tf` (`aws_ssm_service_setting` for `automation/cloudwatch-log-group`) plus cross-region IAM Automation Assume Role — **Wave 1 implementation complete** in `terraform/modules/security-baseline/ssm-automation-logging.tf`, includes per-region CMK + log group + IAM role + service setting | All 3 regions | 2/2/3 | 13 | 1 |

#### Low

| # | Control | Title | Mechanism | Target artifact | Scope | S/B/E | Priority | Wave |
|---|---|---|---|---|---|---|---|---|
| 29 | `IAM.18` | AWS Support role exists | `LZA-Config` | `iam-config.yaml` `roleSets` adding `AWSSupportRole` with `AWSSupportAccess`, target `Root` | All accounts (findings 47, 57) | 1/3/4 | 12 | 1 |
| 30 | `S3.20` | S3 MFA Delete | `Manual` | runbook: root + MFA per bucket | Per-bucket (findings 48, 54) | 1/2/1 | 8 | 2 |
| 31 | `Lambda.3` | Lambda functions in a VPC | `Deferred` | D-5: should `AWSAccelerator-*` Lambdas be VPC-attached? | All `AWSAccelerator-*` functions | 1/3/2 | 11 | 2 |
| 32 | `Lambda.7` | Lambda X-Ray active tracing | `Deferred` | D-6 + P-4 (Lambda monitoring view denied) | All `AWSAccelerator-*` functions | 1/3/2 | 11 | 2 |
| 33 | `S3.7` | S3 cross-region replication | `Terraform` | `terraform/live/<account>/s3-replication/` (only buckets that warrant CRR) | Per-bucket | 1/2/3 | 10 | 2 |
| 34 | `IAM.21` | Customer policies don't use `service:*` wildcards | `Deferred` → `Terraform` | same blocker as `KMS.1` (P-1) (findings 52, 55) | Org-wide | 1/3/2 | 11 | 2 |
| 35 | `S3.13` | S3 lifecycle configurations | `Config-Rule-SSM` | Config rule `s3-lifecycle-policy-check` + SSM custom doc (default: 90d→IA, 180d→Glacier, 365d expire on noncurrent versions) | All buckets (findings 53, 56) | 1/3/3 | 12 | 1 |

### Coverage summary

By severity (distinct entries / total findings incl. duplicates):

| Severity | Distinct | Total |
|---|---|---|
| Critical | 1 | 1 |
| High | 6 | 6 |
| Medium | 21 | ~38 |
| Low | 7 | ~12 |

By standard (per source CSV):

| Standard | Failed |
|---|---|
| CIS AWS Foundations Benchmark v3.0.0 | 7 |
| NIST 800-53 r5 | 22 |
| AWS FSBP v1.0.0 | 21 |
| PCI DSS v4.0.1 | 7 |

By mechanism (distinct entries):

| Mechanism | Count |
|---|---|
| `LZA-Config` | 9 |
| `Config-Rule-SSM` | 7 |
| `Terraform` | 5 |
| `Manual` | 4 |
| `Deferred` | 10 |

### Prioritization framework

Each finding is scored on three axes; the score drives execution order within a wave.

**Severity (S):**

| Severity | Value |
|---|---|
| Critical | 4 |
| High | 3 |
| Medium | 2 |
| Low | 1 |

**Blast radius (B):**

| Reach | Value |
|---|---|
| Single resource, single region | 1 |
| Single account, multi region | 2 |
| Multi account, multi region | 3 |

**Ease of automation (E):** inverse of effort. High value means easy.

| Effort | Value |
|---|---|
| Trivial — one config line, primitive already supported | 4 |
| Moderate — new Config rule + SSM doc, or small Terraform module | 3 |
| Hard — bucket recreation, SCP work, IAM redesign | 2 |
| Manual-only — root + MFA, contact info collection | 1 |

**Aggregation:**

```
priority = (S × 3) + (B × 2) + (E × 1)
```

Severity dominates because PCI compliance treats severity as the primary axis. Blast radius is the second weight because preventive scope is a force multiplier. Ease-of-automation is the smallest weight; it breaks ties between similar-severity items.

Tie-breaker when two items score identically: prefer the larger blast radius (B), then prefer the standard with the most controls failing.

### Rollout waves

| Wave | Scope | Entry criteria | Exit criteria |
|---|---|---|---|
| 0 | Decision sprint (D-1 … D-8) | none | every Wave 2 deferred item has a decision or a documented "park" |
| 1 | PCI account `247514667218` across all 3 regions; every entry tagged Wave 1 | D-2 (CloudTrail strategy) and D-7 (contact info) resolved; others can run in parallel | Security Hub re-aggregation shows targeted findings as `PASSED` for PCI; AWS Config rules show non-compliant resources auto-remediated; LZA pipeline run is green |
| 2 | All other spoke accounts (`Production`, `Development`, `SharedServices`, `Network`, `Perimeter`) | Wave 1 stable for one full re-aggregation cycle | Same controls passing across all spokes |
| 3 | Deferred backfill (rolling) | Decision or permission unblocked | Affected rows moved out of `Deferred` and into a real bucket |

Order within Wave 1 (descending priority):

1. `SSM.7` (Terraform) — Critical, trivial.
2. `IAM.28`, `EC2.10/55/56/57/58/60` (LZA-Config) — High and high-leverage.
3. `EC2.182` (Terraform) — High.
4. `S3.5/9/17`, `SNS.1`, `CloudWatch.16`, `S3.13` (Config-Rule-SSM) — Medium, high coverage.
5. `IAM.18` (LZA-Config) — Low priority but trivial.
6. `S3.10` (Config-Rule-SSM) — Medium.
7. `SSM.6` (Terraform) — Medium.
8. `S3.22/23` (LZA-Config) — Medium, decision-gated.
9. `Account.1` (LZA-Config or Terraform) — Medium, gated on contact info.

Rollback: LZA-Config and Config-Rule-SSM changes are PR-reverted. Terraform changes revert via `terraform apply` of the previous state. Service settings are flipped back via the same Terraform module.

### Decision-Pending Items register

| ID | Related findings | Question | Options | Owner | Impact of delay |
|---|---|---|---|---|---|
| D-1 | `Inspector.1/2/3/4` | Activate Inspector v2 in `us-east-1` and `us-west-2`? Which resource types? | (a) all four resource types both regions; (b) EC2 + ECR only; (c) defer until home region (`us-east-2`) baseline confirmed | Alex | High and Medium findings persist; Wave 2 cannot complete |
| D-2 | `S3.22`, `S3.23` | Extend Control Tower `BaselineCloudTrail` with org-wide S3 data events, or create a new dedicated trail? | (a) extend baseline trail (single source of truth, simpler); (b) create new LZA-managed trail (cleaner separation, double cost) | Alex | **RESOLVED 2026-06-15: option (a) — extend baseline trail via Terraform `security-baseline` module to avoid duplicate trail cost. LZA has no primitive to add selectors to a Control Tower-managed trail, so Terraform is the clean implementation. Operational caveat: re-running Control Tower landing-zone setup wizard can reset custom selectors; mitigation is a re-apply step in `pci-onboarding-guide.md`.** |
| D-3 | `CloudFormation.3` | Enable termination protection on LZA-managed stacks without breaking the pipeline? | (a) workload stacks only; (b) everywhere, validate LZA pipeline tolerates it; (c) park — accept the finding for LZA-managed stacks | LZA owner | Medium finding persists; (c) requires a documented compensating control |
| D-4 | `CloudFormation.4` | Attach a service role to LZA-managed stacks? | (a) yes via LZA — confirm primitive; (b) park — LZA pipeline already runs as a controlled principal | LZA owner | Medium finding persists |
| D-5 | `Lambda.3` | Place `AWSAccelerator-*` Lambdas in a VPC? | (a) yes — design VPC + endpoint dependencies; (b) no — accept the failure on LZA-owned functions and document compensating controls | LZA owner | Low finding persists |
| D-6 | `Lambda.7` | Enable X-Ray on `AWSAccelerator-*` Lambdas? | (a) yes if LZA exposes a flag; (b) no | LZA owner | Low finding persists |
| D-7 | `Account.1` | Provide alternate security contact details (name, email, phone, title) | (a) shared security inbox; (b) individual on-call | Security lead | **RESOLVED 2026-06-15: option (a) — shared inbox. Values: name `Alex Gonzalez`, email `security@nebulariscloud.com`, phone `+17875863211`, title `CEO`. Same contact applied to every account in the org. Implemented via `aws_account_alternate_contact` in the `security-baseline` Terraform module.** |
| D-8 | `S3.11` | Which buckets need event notifications, and to what destination? | (a) log buckets only; (b) all buckets to a security SNS topic; (c) per-bucket business decision | Platform | Medium finding persists; broad enablement adds noise without a clear receiver |
| D-9 | `S3.22`, `S3.23` | How to extend the Control Tower `BaselineCloudTrail` (in the Management account) with S3 data event selectors, given that Terraform's `TerraformExecution` trust path excludes Management? | (a) add a narrow `cloudtrail:PutEventSelectors` capability to a Management-only role via LZA `iam-config.yaml`, then a dedicated `terraform/live/management/cloudtrail-data-events/` leaf; (b) use LZA `customizations-config.yaml` with a custom CloudFormation stack that calls `PutEventSelectors`; (c) one-time manual change in the Console plus a runbook entry to re-apply if Control Tower upgrades reset selectors | Alex / LZA owner | **RESOLVED 2026-06-15: option (c) — one-time manual change documented in `cloudtrail-data-events-runbook.md`. Event selectors are stable once set; no ongoing reconciliation needed. The runbook captures the procedure, the verification commands, the post-change Compliance_Evidence to capture, and the Control Tower upgrade re-check step so the change is not lost.** |

### Permission Gaps and Manual Prerequisites register

| ID | Related findings | Gap or prerequisite | Owner | Resolution path |
|---|---|---|---|---|
| P-1 | `KMS.1`, `IAM.21` | `iam:ListPolicies` denied to the analysis principal | IAM admin | Grant `IAMReadOnlyAccess` (or narrower) to the principal used for compliance review; re-run analysis |
| P-2 | `S3.20` | S3 MFA Delete requires root + MFA | Account root holder | Schedule a session with the root holder; capture compliance evidence |
| P-3 | `S3.15` | Object Lock can only be enabled at bucket creation; `awsconfigconforms-pci-dss-templates-icc-pr` already has objects | Platform | Empty buckets: drop and recreate via Terraform; non-empty: create new locked bucket, S3 Batch Replication for content, swap consumers |
| P-4 | `Lambda.7` | Insufficient permission to view X-Ray monitoring settings | IAM admin | Grant `AWSXrayReadOnlyAccess` and `lambda:GetFunctionConfiguration` |
| P-5 | `S3.22`, `S3.23` | Only existing trail is `aws-controltower-BaselineCloudTrail` with no data events | Control Tower owner | Tied to D-2; resolve decision then apply selectors |

## Correctness Properties

Properties the strategy must hold throughout its lifetime. These are testable invariants of the disposition table and registers, not of the AWS resources themselves.

### Property 1: Inventory completeness

Every finding from the source CSPM CSV appears exactly once as an inventory entry in **Disposition table — full inventory**, with duplicates collapsed and resource scope enumerated.

**Validates: Requirements 1.1, 1.3, 12.1, 12.6**

### Property 2: Single mechanism per entry

Every inventory entry has exactly one `mechanism` value drawn from `LZA-Config`, `Config-Rule-SSM`, `Terraform`, `Manual`, `Deferred`.

**Validates: Requirements 2.1, 3.3**

### Property 3: Deferred entries are tracked

Every entry whose `mechanism` is `Deferred` has at least one matching entry in the **Decision-Pending Items register** or the **Permission Gaps and Manual Prerequisites register**.

**Validates: Requirements 1.5, 2.7, 8.1, 8.2, 9.1, 9.2**

### Property 4: Wave 1 prerequisites are resolved or tracked

Every entry assigned Wave 1 either has all prerequisites resolved, or its prerequisites are tracked in `P-*` with a resolution path.

**Validates: Requirements 3.4, 7.2, 9.2**

### Property 5: LZA-Config target references a real primitive

For every `LZA-Config` entry, the target artifact references a real LZA configuration key in `global-config.yaml`, `security-config.yaml`, `network-config.yaml`, `iam-config.yaml`, `organization-config.yaml`, `accounts-config.yaml`, or `customizations-config.yaml`.

**Validates: Requirements 2.3, 2.9**

### Property 6: Config-Rule-SSM artifacts are real or scheduled

For every `Config-Rule-SSM` entry, the Config rule identifier and SSM document name are either AWS-managed (verified against AWS docs) or are added to `awsConfig.ruleSets` and `ssmAutomation.documentSets` in the same implementation spec.

**Validates: Requirements 2.4, 2.10**

### Property 7: Priority score is correctly computed

The priority score for every entry equals `(S × 3) + (B × 2) + (E × 1)` for the recorded S/B/E values.

**Validates: Requirements 4.1, 4.2, 4.3, 4.4**

### Property 8: Wave order respects priority

Wave assignment respects priority within a wave: no entry with a strictly lower priority score precedes a strictly higher one in the documented execution order, except where prerequisites force a different sequence.

**Validates: Requirements 4.5, 4.6, 7.4**

### Property 9: Default deployment scope is org-wide

An `LZA-Config` or `Config-Rule-SSM` disposition deploys with `deploymentTargets.organizationalUnits: [Root]` unless a documented exception scopes it narrower.

**Validates: Requirements 6.1, 6.2, 6.4**

### Property 10: Register resolution updates the table

Resolution of any `D-*` or `P-*` register entry requires updating the corresponding inventory row's `mechanism`, `target_artifact`, and `wave` in the same change.

**Validates: Requirements 8.4, 9.4, 11.5**

## Error Handling

These cover failure modes during execution and re-evaluation, not runtime errors of fixed resources.

### Source CSPM CSV is incomplete or ambiguous

If a future snapshot lacks region or scope information for a finding, mark the inventory entry `Deferred` with reason "ambiguous source", route to the Permission Gaps register as a P-* entry against the analysis principal, and re-run the rubric once the source is completed.

### LZA primitive does not exist for an LZA-Config disposition

If implementation discovers LZA does not actually expose the primitive named in the target artifact (LZA version drift), demote the entry to `Config-Rule-SSM` if a managed rule exists, otherwise to `Terraform`, otherwise `Manual`. Update the inventory row and document the demotion in the spec changelog.

### Config managed rule does not exist for a Config-Rule-SSM disposition

If the rule identifier listed is not a managed rule in the active region, the implementation spec MUST author a custom Config rule (Lambda-backed) before proceeding, or demote to `Terraform`.

### SSM Automation document does not exist for a Config-Rule-SSM disposition

If the SSM document is not AWS-managed, the implementation spec MUST author a custom document under `ssm-documents/` and a remediation IAM role under `ssm-remediation-roles/`, following the existing examples.

### LZA pipeline regression after a Wave 1 change

Roll back the offending PR. If multiple changes are in flight, isolate by reverting commits in reverse order and re-running until green. Keep all Wave 1 changes in small, single-purpose PRs to make this cheap.

### Auto-remediation fails for a per-resource Config rule

If `maximumAutomaticAttempts` is exhausted, AWS Config marks the resource non-compliant. Triage: (a) fix the SSM doc input parameters, (b) widen the IAM remediation role, (c) demote the entry to `Manual` for that specific resource and capture in the runbook.

### Manual prerequisite cannot be satisfied within the rollout window

Park the entry. Update the row's owner to "Risk-accepted", capture the compensating control, and add it to the next quarterly review.

### Drift after a successful remediation

If a remediated control flips back to failing on the next aggregation, treat as a drift event:

1. For `LZA-Config`: the next pipeline run reverts the drift; raise an issue if drift occurred between runs.
2. For `Config-Rule-SSM`: AWS Config re-flags and SSM re-remediates automatically.
3. For `Terraform`: schedule a `terraform apply` to revert the drifted setting; consider adding an SCP guardrail (see spec 7 below) to make the setting non-changeable.

### Standard or finding deprecated

If AWS retires a standard or a control in a future Security Hub release, mark the row "Deprecated", retain it for audit history, and exclude from active scoring.

## Testing Strategy

### Per-mechanism verification

| Mechanism | Verification |
|---|---|
| `LZA-Config` | LZA pipeline run completes green; CloudFormation stack outputs reflect the change; Security Hub re-scan shows the control passing |
| `Config-Rule-SSM` | AWS Config compliance dashboard shows resources transitioning from `NON_COMPLIANT` to `COMPLIANT` within `retryAttemptSeconds × maximumAutomaticAttempts`; SSM Automation execution history shows successful runs |
| `Terraform` | `terraform plan` is a no-op after apply; AWS API confirms the service setting (`aws ssm get-service-setting`, `aws ec2 get-snapshot-block-public-access-state`); Security Hub re-scan shows the control passing |
| `Manual` | Compliance evidence captured (screenshot or CSV export) and stored alongside this spec; the corresponding runbook entry is updated with the date and operator |
| `Deferred` | Decision-Pending Items register entry resolved with date, owner, and outcome; or Permission Gap entry closed with grant date |

### Re-scan cadence

- After each LZA pipeline run.
- Weekly Security Hub aggregation review during Wave 1 and Wave 2.
- Monthly aggregation review thereafter.

### Drift detection

- LZA's `scpRevertChangesConfig.enable: true` reverts SCP drift. Confirm equivalent reversion exists for Config rules and SSM documents (LZA pipeline reverts them on next run).
- Add an SCP statement (see spec 7 in **Implementation specs to spawn**) that prevents disabling Inspector, EBS public access block, SSM document public sharing, or SSM Automation logging once enabled. Converts these from one-shot fixes into preventive controls.
- AWS Config compliance state itself is the drift signal for `Config-Rule-SSM` items.

### Acceptance evidence per wave

| Wave | Evidence captured |
|---|---|
| 0 | Decision document for D-1 … D-8 with date and owner sign-off |
| 1 | Security Hub aggregation export for PCI account showing targeted controls as `PASSED`; AWS Config compliance dashboard screenshot; Terraform `plan` showing no changes |
| 2 | Same evidence for each spoke account |
| 3 | Updated Disposition table with no remaining `Deferred` entries (or documented "park" with compensating control) |

### Implementation specs to spawn from this design

The implementation work is intentionally not in this document. Each batch becomes its own spec under `.kiro/specs/`. Suggested splits:

1. ✅ **`security-baseline-terraform-module`** — IN FLIGHT. Covers `SSM.7`, `EC2.182`, `SSM.6`, `Account.1`, and the deferred Inspector findings once D-1 lands. Wave 1 module + leaf code complete; pending Wave 1 PR plan/apply/evidence (tasks 23–26).
2. **`lza-config-rules-and-ssm-remediations`** — NEXT UP. Adds `Config-Rule-SSM` entries to `awsConfig.ruleSets` and `ssmAutomation.documentSets` in `security-config.yaml`. Includes new SSM documents under `ssm-documents/` and IAM remediation roles under `ssm-remediation-roles/`.
3. **`lza-iam-and-account-baseline`** — covers `IAM.18` (support role via `iam-config.yaml`) and any IAM password policy adjustments.
4. **`lza-cloudtrail-data-events`** — RESOLVED (manual). See `cloudtrail-data-events-runbook.md` (D-9 option C). No spec needed; the runbook is the deliverable.
5. **`lza-vpc-endpoints-pci-coverage`** — investigates and confirms why `vpc-0766c6bceb81ea3fa` is failing the EC2.10/55/56/57/58/60 controls despite the central endpoints already being defined. Likely a `useCentralEndpoints` toggle or a missing PCI VPC entry in `network-config.yaml`.
6. **`s3-mfa-delete-and-object-lock-runbook`** — runbook spec with no implementation, just the procedure and evidence capture format.
7. **`scp-preventive-controls-for-service-settings`** — new SCPs that prevent disabling Inspector, EBS public block, SSM public sharing, and SSM Automation logging once enabled. Converts Wave 1 Terraform fixes into permanent guardrails.

The order of spec creation should follow priority within Wave 1: spec 1 (in flight) and spec 2 are highest-leverage. Spec 5 unblocks the EC2 endpoint findings, which look surprising given the existing network config and need investigation before any code change.
