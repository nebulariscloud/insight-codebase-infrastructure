# Requirements Document

## Introduction

This feature extends the existing `aws-accelerator-config/security-config.yaml` `awsConfig.ruleSets` and `ssmAutomation.documentSets` blocks with seven AWS Config rule + SSM Automation document pairs that detect and auto-remediate per-resource Security Hub findings org-wide. The pattern follows the two existing rules in this repo with `remediation.automatic: true` (`ec2-instance-profile-attached`, `elb-logging-enabled`); the new rules add detection and remediation for S3 bucket sprawl, SNS topic encryption, and CloudWatch log group retention across every account in the organization.

This is the second wave of work spun out of the parent strategy spec `security-hub-findings-remediation-strategy`. It is the highest finding-count knockdown of the entire strategy: a single PR closes ~12 Medium-severity findings on the PCI account today and prevents the same controls from regressing on every present and future spoke account because the rules deploy to `Root`.

The feature is implemented entirely through LZA configuration. There is no Terraform, no manual unblock, no per-account leaf. The LZA pipeline reads `security-config.yaml` and propagates the new rules and remediation documents to every enrolled account. The SSM Automation documents are shared via the existing `ssmAutomation.documentSets` block (already shared to `Root`), and AWS Config triggers them automatically when a non-compliant resource is detected.

The feature explicitly does not change the resource-level remediation behavior of LZA-managed resources. AWS Config evaluates resources, AWS Config triggers SSM Automation, and SSM Automation calls the AWS API. LZA-managed buckets, topics, and log groups should already be compliant with these rules; the rules catch and remediate the non-LZA resources that drift over time.

## Glossary

- **Config_Rule_SSM_Pair**: A single AWS Config rule paired with an SSM Automation document, configured in `security-config.yaml` so non-compliant resources trigger automatic remediation.
- **Existing_Pattern**: The wiring established in `aws-accelerator-config/security-config.yaml` for `ec2-instance-profile-attached` and `elb-logging-enabled`. Each entry has a Config rule under `awsConfig.ruleSets[*].rules[*]` with `remediation.automatic: true`, plus a corresponding SSM document under `ssmAutomation.documentSets[*].documents[*]`, plus an IAM role policy file under `ssm-remediation-roles/`.
- **Managed_Config_Rule**: An AWS-published Config rule identifier (e.g., `S3_BUCKET_SSL_REQUESTS_ONLY`) that is supported in every Active_Region without custom Lambda authoring.
- **Managed_SSM_Document**: An AWS-published SSM Automation document (e.g., `AWSConfigRemediation-RestrictBucketSSLRequestsOnly`) that performs the remediation for a Managed_Config_Rule.
- **Custom_SSM_Document**: An SSM Automation document authored in this repo under `aws-accelerator-config/ssm-documents/`, used when no Managed_SSM_Document exists for a control.
- **Remediation_IAM_Role_Policy**: A JSON file under `aws-accelerator-config/ssm-remediation-roles/` that grants the minimum AWS API permissions the SSM document needs to perform its remediation.
- **Active_Region**: One of `us-east-1`, `us-east-2`, `us-west-2`.
- **Org_Wide_Deployment_Target**: `deploymentTargets.organizationalUnits: [Root]`. Every account inherits the rule.
- **In_Scope_Account**: Any non-Management account in the organization. Wave 1 (PCI) is already complete; this spec applies to every spoke including PCI for resource types covered by the rules.
- **Auto_Remediation**: A `remediation` block on a Config rule with `automatic: true`, `retryAttemptSeconds`, and `maximumAutomaticAttempts`. AWS Config invokes the SSM document when a resource is `NON_COMPLIANT`.
- **Compliance_Evidence**: Captured AWS Config compliance dashboard state and Security Hub finding state showing the targeted controls move to `PASSED` for the In_Scope_Account.
- **LZA_Reconciliation**: An LZA pipeline run that reads `security-config.yaml` and deploys the rules + SSM documents + IAM roles across every enrolled account.

## Requirements

### Requirement 1: Wiring follows the existing pattern

**User Story:** As a contributor reviewing this PR, I want the new Config rule + SSM document pairs to follow the existing wiring in `security-config.yaml` so the change is recognizable, reviewable, and consistent with the rest of the file.

#### Acceptance Criteria

1. THE feature SHALL add new Config rule entries under the existing `awsConfig.ruleSets[*]` block whose `deploymentTargets.organizationalUnits` is `[Root]`, mirroring the existing `Existing_Pattern` for org-wide rules.
2. THE feature SHALL add new SSM Automation document entries under the existing `ssmAutomation.documentSets[*]` block whose `shareTargets.organizationalUnits` is `[Root]`.
3. THE feature SHALL preserve every existing rule and document in `security-config.yaml` without modification.
4. THE feature SHALL NOT introduce a new top-level configuration key in `security-config.yaml`.
5. THE feature SHALL NOT change the existing `Existing_Pattern` wiring for `ec2-instance-profile-attached` or `elb-logging-enabled`.

### Requirement 2: S3.5 — buckets require SSL

**User Story:** As the security owner, I want every S3 bucket in the org to reject HTTP requests, so that data in transit is always encrypted.

#### Acceptance Criteria

1. THE feature SHALL add a Config rule named `{{ AcceleratorPrefix }}-s3-bucket-ssl-requests-only` with identifier `S3_BUCKET_SSL_REQUESTS_ONLY` and `complianceResourceTypes: [AWS::S3::Bucket]`, deployed to `Root`.
2. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
3. THE remediation `targetId` SHALL reference the AWS managed SSM document `AWSConfigRemediation-RestrictBucketSSLRequestsOnly`.
4. THE remediation parameters SHALL pass `BucketName` derived from `RESOURCE_ID`.
5. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/s3-ssl-requests-only-remediation-role.json` granting the minimum permissions to read and update bucket policies.

### Requirement 3: S3.9 — buckets have server access logging enabled

**User Story:** As the security owner, I want every S3 bucket to send server access logs to a centralized destination, so that bucket access is auditable.

#### Acceptance Criteria

1. THE feature SHALL add a Config rule named `{{ AcceleratorPrefix }}-s3-bucket-logging-enabled` with identifier `S3_BUCKET_LOGGING_ENABLED` and `complianceResourceTypes: [AWS::S3::Bucket]`, deployed to `Root`.
2. THE Config rule SHALL include `inputParameters` for an allowed target log bucket pattern that references the LZA-published access-log bucket via `${ACCEL_LOOKUP::Bucket:s3AccessLogs}` (or the equivalent resolver path used by LZA in this repo's existing rules).
3. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
4. THE remediation `targetId` SHALL reference an SSM document that enables server access logging on the bucket pointing at the LZA access-log bucket. The feature SHALL prefer the AWS managed document `AWS-ConfigureS3BucketLogging` if it exists in every Active_Region; otherwise the feature SHALL author a `Custom_SSM_Document` at `ssm-documents/enable-s3-bucket-logging.yaml`.
5. THE remediation parameters SHALL pass `BucketName` derived from `RESOURCE_ID` and `TargetBucket` derived from the LZA-published access-log bucket lookup.
6. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/s3-bucket-logging-remediation-role.json` granting the minimum permissions to read bucket logging configuration and write a target logging configuration.

### Requirement 4: S3.17 — buckets encrypted with an LZA-managed CMK

**User Story:** As the security owner, I want every S3 bucket to use SSE-KMS encryption with a customer-managed KMS key, so that bucket data is encrypted with auditable, rotatable keys we own — not the AWS-managed S3 key.

#### Acceptance Criteria

1. THE feature SHALL provision a per-region customer-managed KMS key for default S3 encryption via LZA's `centralSecurityServices.keyManagementService` (or the equivalent LZA primitive that exposes org-wide CMK provisioning), deployed to `Root`.
2. THE per-region CMK SHALL have:
    a. `enableKeyRotation: true`.
    b. A key alias of `alias/accelerator/s3-default`.
    c. A key policy granting:
        - `kms:*` to the account root (standard).
        - `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey` to the `s3.amazonaws.com` service principal scoped to the bucket's account via `kms:CallerAccount`.
        - `kms:Decrypt` and `kms:GenerateDataKey*` to the LZA-managed log-archive principal so cross-account access logging continues to work after buckets are re-encrypted.
3. LZA SHALL publish the per-region CMK ARN to SSM Parameter Store at `/accelerator/kms/Accelerator-S3-Default/key-arn` (or the path produced by LZA's standard CMK publishing mechanism).
4. THE feature SHALL add a Config rule named `{{ AcceleratorPrefix }}-s3-default-encryption-kms` with identifier `S3_DEFAULT_ENCRYPTION_KMS` and `complianceResourceTypes: [AWS::S3::Bucket]`, deployed to `Root`.
5. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
6. THE remediation `targetId` SHALL reference a `Custom_SSM_Document` at `ssm-documents/enable-s3-bucket-kms-encryption.yaml` that:
    a. Reads the per-region CMK ARN from `/accelerator/kms/Accelerator-S3-Default/key-arn`.
    b. Calls `s3:PutBucketEncryption` with `SSEAlgorithm: aws:kms`, `KMSMasterKeyID` set to the read ARN, and `BucketKeyEnabled: true` (reduces KMS request cost).
7. THE remediation parameters SHALL pass `BucketName` derived from `RESOURCE_ID`. The CMK ARN is resolved inside the SSM document via SSM Parameter Store, not via parameter input, so the remediation works in every region without per-region rule duplication.
8. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/s3-bucket-kms-encryption-remediation-role.json` granting:
    a. `s3:GetEncryptionConfiguration`, `s3:PutEncryptionConfiguration` on `*`.
    b. `ssm:GetParameter` on `arn:${PARTITION}:ssm:*:*:parameter/accelerator/kms/Accelerator-S3-Default/key-arn`.
    c. No KMS actions are required by the remediation role itself; the bucket performs the encrypt operation under the bucket's account context using the CMK's key policy.

### Requirement 5: S3.10 and S3.13 — bucket lifecycle configuration (compliance retention, transitions only)

**User Story:** As the security owner of a compliance-driven workload, I want every S3 bucket to have a lifecycle configuration that optimizes storage cost without ever expiring data, so that the cardholder-data retention posture is preserved while old data moves to cheaper storage classes.

#### Acceptance Criteria

1. THE feature SHALL add a single Config rule named `{{ AcceleratorPrefix }}-s3-lifecycle-policy-check` with identifier `S3_LIFECYCLE_POLICY_CHECK` and `complianceResourceTypes: [AWS::S3::Bucket]`, deployed to `Root`. This single rule covers BOTH `S3.10` (versioning + lifecycle) and `S3.13` (lifecycle present at all).
2. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
3. THE remediation `targetId` SHALL reference a `Custom_SSM_Document` at `ssm-documents/apply-default-s3-lifecycle.yaml` that applies a default lifecycle configuration with the following rule structure:
    a. **No `Expiration` rule.** Current-version objects are never expired by lifecycle.
    b. **No `NoncurrentVersionExpiration` rule.** Noncurrent versions are never expired by lifecycle.
    c. **`Transitions`** for current versions: `STANDARD_IA` after 90 days, `GLACIER` after 180 days, `DEEP_ARCHIVE` after 365 days.
    d. **`NoncurrentVersionTransitions`**: `STANDARD_IA` after 30 days, `GLACIER` after 90 days, `DEEP_ARCHIVE` after 180 days.
    e. **`AbortIncompleteMultipartUpload.DaysAfterInitiation: 7`** matches the existing LZA pattern in `global-config.yaml`.
    f. **`Filter.Prefix: ""`** (rule applies to every object in the bucket).
4. THE feature SHALL document, in the SSM document and in the strategy disposition table, that:
    a. The default lifecycle never expires data; this is intentional for compliance retention.
    b. Buckets that need different lifecycle behavior (e.g., short-lived staging buckets) must be moved out of the auto-remediation path by tag-based exclusion.
5. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/s3-lifecycle-remediation-role.json` granting `s3:PutLifecycleConfiguration` and `s3:GetLifecycleConfiguration`.
6. THE feature SHALL document the tag-based override mechanism: a bucket tagged `accelerator:s3-lifecycle-managed = false` SHALL be excluded from auto-remediation (via Config rule scope filter, not via the SSM document).

### Requirement 6: SNS.1 — SNS topics encrypted with KMS

**User Story:** As the security owner, I want SNS topics to be encrypted at rest with KMS, so that messages held by SNS are not stored in plaintext.

#### Acceptance Criteria

1. THE feature SHALL add a Config rule named `{{ AcceleratorPrefix }}-sns-encrypted-kms` with identifier `SNS_ENCRYPTED_KMS` and `complianceResourceTypes: [AWS::SNS::Topic]`, deployed to `Root`.
2. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
3. THE remediation `targetId` SHALL reference the AWS managed SSM document `AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic` IF available; otherwise a `Custom_SSM_Document` at `ssm-documents/enable-sns-kms-encryption.yaml` that calls `sns:SetTopicAttributes` with `KmsMasterKeyId: alias/aws/sns`.
4. THE remediation parameters SHALL pass `TopicArn` derived from `RESOURCE_ID` and `KmsKeyArn` defaulted to `alias/aws/sns`.
5. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/sns-kms-encryption-remediation-role.json`.

### Requirement 7: CloudWatch.16 — log group retention configured

**User Story:** As the security owner, I want every CloudWatch log group to have a non-zero retention period, so that logs are not retained indefinitely (unbounded cost) or deleted prematurely (loss of audit history).

#### Acceptance Criteria

1. THE feature SHALL add a Config rule named `{{ AcceleratorPrefix }}-cw-loggroup-retention-period-check` with identifier `CW_LOGGROUP_RETENTION_PERIOD_CHECK` and `complianceResourceTypes: [AWS::Logs::LogGroup]`, deployed to `Root`.
2. THE Config rule SHALL include `inputParameters` setting `MinRetentionTime` to `365` (matching the existing `cloudwatchLogRetentionInDays: 365` default in `global-config.yaml`).
3. THE Config rule SHALL include a `remediation` block with `automatic: true`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
4. THE remediation `targetId` SHALL reference the AWS managed SSM document `AWS-UpdateCloudWatchLogGroupRetention` IF available in all Active_Regions; otherwise a `Custom_SSM_Document` at `ssm-documents/set-cloudwatch-log-group-retention.yaml` that calls `logs:PutRetentionPolicy` with `retentionInDays: 365`.
5. THE remediation parameters SHALL pass `LogGroupName` derived from `RESOURCE_ID` and `RetentionInDays: 365`.
6. THE remediation `rolePolicyFile` SHALL reference an IAM role policy at `ssm-remediation-roles/cloudwatch-log-retention-remediation-role.json`.

### Requirement 8: Auto-remediation safety and IAM least privilege

**User Story:** As the security owner, I want every remediation IAM role to have the minimum permissions needed and the remediation to fail closed if it cannot complete, so that the auto-remediation surface does not become a back door.

#### Acceptance Criteria

1. EACH new `Remediation_IAM_Role_Policy` SHALL grant only the AWS API actions required by its specific SSM document. No wildcards on `Action` for service-level grants (e.g., `s3:*` is forbidden).
2. EACH new `Remediation_IAM_Role_Policy` SHALL scope `Resource` to specific ARNs or to `*` only when the SSM document is parameterized over `RESOURCE_ID` and the AWS API does not accept resource-scoped IAM (in which case the Config rule itself enforces resource scoping).
3. EACH `remediation` block SHALL set `maximumAutomaticAttempts` to a finite value (`5` matches the existing pattern); unlimited retries are forbidden.
4. EACH `remediation` block SHALL set `retryAttemptSeconds` to a value at least `60`.
5. THE feature SHALL NOT grant any new permissions to the LZA-managed `TerraformExecution` role; SSM Automation runs under a dedicated remediation role created from the `rolePolicyFile`.

### Requirement 9: Region coverage

**User Story:** As the security owner, I want the new rules to evaluate resources in every active region of every account, so that no region is silently exempt.

#### Acceptance Criteria

1. EACH Config rule SHALL be deployed to every Active_Region by virtue of being declared at the OU level (`Root`); LZA propagates the rule to every region in `enabledRegions`.
2. WHEN a Managed_SSM_Document used by a remediation does not exist in every Active_Region, THE feature SHALL author the corresponding `Custom_SSM_Document` so the remediation works in every region.
3. THE feature SHALL document, in the spec design doc and in the strategy disposition table, any region-specific quirk discovered during implementation (e.g., a managed document missing from a specific region).

### Requirement 10: Existing-resource remediation behavior

**User Story:** As the security owner, I want the new rules to remediate existing non-compliant resources after deployment, not just future resources, so that today's compliance gap is closed.

#### Acceptance Criteria

1. AFTER the LZA pipeline reconciles the new rules, AWS Config SHALL evaluate every existing in-scope resource against each new rule.
2. WHEN a resource is `NON_COMPLIANT`, AWS Config SHALL invoke the configured SSM document up to `maximumAutomaticAttempts` times.
3. WHEN remediation succeeds, AWS Config SHALL re-evaluate the resource and report `COMPLIANT`.
4. WHEN remediation fails after `maximumAutomaticAttempts`, AWS Config SHALL leave the resource `NON_COMPLIANT` with the failure recorded; manual triage is required.
5. THE feature SHALL document, in the spec README, the procedure for triaging a stuck `NON_COMPLIANT` resource (read CloudWatch Logs for the SSM execution; widen the IAM role if a missing permission is the cause; or move the resource out of remediation scope if the rule does not apply).

### Requirement 11: PCI account verification

**User Story:** As the security owner, I want each new rule's effect on the PCI account explicitly verified after the LZA pipeline runs, so that the CSPM findings move from `FAILED` to `PASSED` and the change in state is captured as evidence.

#### Acceptance Criteria

1. AFTER the LZA pipeline reconciles, THE feature SHALL include a verification step that confirms each new rule appears in the AWS Config console for the PCI account in every Active_Region.
2. THE verification step SHALL confirm that each rule reports a compliance state for at least one resource (i.e., the rule is actually evaluating).
3. THE verification step SHALL confirm, after one Security Hub aggregation cycle (~1 hour), that the targeted control IDs (`S3.5`, `S3.9`, `S3.10`, `S3.13`, `S3.17`, `SNS.1`, `CloudWatch.16`) are in `PASSED` state for the PCI account.
4. THE feature SHALL capture the AWS Config compliance dashboard state and the Security Hub findings export as Compliance_Evidence; the storage location SHALL be referenced in the parent strategy spec's evidence appendix.

### Requirement 12: Non-PCI account propagation

**User Story:** As the platform owner, I want the same rules to evaluate every other spoke account in the org, so that I do not need a separate spec or rollout for each account.

#### Acceptance Criteria

1. BY virtue of `deploymentTargets: organizationalUnits: [Root]`, the rules SHALL deploy to every account in the org including `LogArchive`, `Audit`, `SharedServices`, `Network`, `Perimeter`, `Production`, `Development`, and `PCI`.
2. THE feature SHALL document, in the spec design doc, that no per-account leaf or per-account spec is required; the LZA pipeline run is the sole rollout mechanism.
3. WHEN a future account is enrolled in the org, THE rules SHALL evaluate that account from its first LZA-managed pipeline run without any additional configuration in this repo.

### Requirement 13: Rollback

**User Story:** As the security owner, I want a defined rollback procedure if a new rule causes unintended remediations, so that we can revert quickly.

#### Acceptance Criteria

1. THE feature SHALL document, in the spec design doc, the rollback procedure for each rule: revert the rule's `remediation.automatic` to `false` (so detection continues but auto-remediation stops), then run the LZA pipeline.
2. THE feature SHALL document a faster emergency rollback: remove the entire rule entry from `security-config.yaml`, run LZA. AWS Config will mark the rule as deleted across the org.
3. THE feature SHALL document, for each rule, the resources that are most likely to be inappropriately remediated and call out tags or scope filters that can exclude them (e.g., LZA-managed log groups already have retention set; the CloudWatch.16 rule will report them compliant and not remediate).

### Requirement 14: Spec scope and explicit out-of-scope

**User Story:** As a reviewer, I want the spec to call out which strategy rows are explicitly not covered, so that future contributors do not assume a gap is a bug.

#### Acceptance Criteria

1. THE feature SHALL explicitly cover `S3.5`, `S3.9`, `S3.10`, `S3.13`, `S3.17`, `SNS.1`, and `CloudWatch.16` from the parent strategy.
2. THE feature SHALL explicitly NOT cover `S3.7` (cross-region replication; per-bucket business decision), `S3.11` (event notifications; per-bucket business decision), `S3.15` (Object Lock; bucket recreation required), `S3.20` (MFA Delete; root + MFA only), or `S3.22` / `S3.23` (CloudTrail data events; resolved manually via D-9 runbook).
3. THE feature SHALL NOT modify the `accessAnalyzer`, `iamPasswordPolicy`, `cloudWatch.metricSets`, `centralSecurityServices.macie`, `centralSecurityServices.guardduty`, `centralSecurityServices.securityHub`, or `centralSecurityServices.ebsDefaultVolumeEncryption` blocks of `security-config.yaml`.
4. THE feature SHALL NOT change any LZA configuration outside `security-config.yaml`, `ssm-documents/`, and `ssm-remediation-roles/`. EXCEPTION: provisioning the per-region S3 default CMK (Requirement 4.1-4.3) MAY require additions to `security-config.yaml`'s `centralSecurityServices.keyManagementService` (or equivalent LZA primitive) and to `replacements-config.yaml` if the CMK alias is templated.
5. THE feature SHALL NOT add detective-only Config rules (rules without `remediation.automatic: true`); this spec is for the auto-remediation pattern. Detective-only additions belong in a separate spec.
6. THE feature SHALL NOT add Config rules for controls that did not appear as failing in the source CSPM CSV (e.g., `ELB.6`, `ELB.4`). Adding preventive coverage for non-failing controls is out of scope; revisit when those controls actually fail or as part of a separate hardening spec.

## Design Decisions

This section captures the design choices made during requirements gathering so future contributors can see the rationale, not just the rules.

### Decision 1: Cover only failing controls from the source CSPM CSV

The source CSV showed `S3.5`, `S3.9`, `S3.10`, `S3.13`, `S3.17`, `SNS.1`, and `CloudWatch.16` as failing. Other controls in the same families (`ELB.4`, `ELB.6`, `ELB.7`, etc.) did not appear as failing on any account. This spec covers the actual gap; preventive hardening for non-failing controls is deferred to a separate spec when they become relevant.

### Decision 2: Single Config rule covers both `S3.10` and `S3.13`

`S3.13` checks for any lifecycle configuration. `S3.10` checks for lifecycle on versioned buckets. A single `S3_LIFECYCLE_POLICY_CHECK` rule satisfies both in practice because applying the default lifecycle to every bucket also applies it to versioned ones. Keeping it as one rule reduces operational complexity and is simpler to reason about.

### Decision 3: Lifecycle never expires data — transitions only

This is a compliance-driven workload. The default lifecycle never expires current or noncurrent versions; it only transitions them to colder storage classes. This optimizes cost without ever risking data loss against retention requirements. Buckets that need different behavior are excluded by the `accelerator:s3-lifecycle-managed = false` tag; the default is opinionated for the most common compliance case.

### Decision 4: S3.17 uses an LZA-managed customer CMK, not `alias/aws/s3`

`alias/aws/s3` (AWS-managed) would technically pass the Config rule, but auditors increasingly want a customer-managed key with explicit policy and rotation control. We provision a per-region CMK (`alias/accelerator/s3-default`) via LZA's `keyManagementService` block, publish its ARN to SSM Parameter Store, and the remediation document reads the ARN at runtime. This makes the spec scope larger by ~15% but produces the cleaner long-term architecture: every account in every region gets its own CMK by default, and remediation works without a key-distribution problem.

### Decision 5: All rules deploy to `Root`, not just PCI

The findings appeared on the PCI account, but the same rules benefit every spoke. Deploying to `Root` means PCI is the leading edge for verification; everywhere else inherits the controls automatically. New accounts onboarded later inherit the rules from their first LZA pipeline run.

### Decision 6: Auto-remediation uses `automatic: true` with `maximumAutomaticAttempts: 5`

Matches the existing pattern in this repo (`ec2-instance-profile-attached`, `elb-logging-enabled`). Five attempts caps the blast radius if a rule misfires; AWS Config records each attempt in CloudWatch Logs for triage. Rolling back is `automatic: true` → `automatic: false` plus an LZA pipeline run.

### Decision 7: SSM remediation IAM roles are per-rule, not shared

Each remediation has its own `rolePolicyFile` under `ssm-remediation-roles/`. Sharing a role across rules would either over-grant permissions to some rules or leave others under-permissioned. Per-rule roles are the existing pattern and the principle of least privilege.

### Decision 8: Tag-based exclusion for buckets that need different lifecycle

Rather than building per-bucket exception lists into the rule scope, we use a tag (`accelerator:s3-lifecycle-managed = false`) to opt buckets out of the rule's resource scope filter. This keeps the rule definition simple, makes overrides visible at the resource level, and doesn't require editing `security-config.yaml` for each exception.
