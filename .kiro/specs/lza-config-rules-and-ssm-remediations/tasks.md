# Implementation Plan

## Overview

Execution plan for `lza-config-rules-and-ssm-remediations`. The whole spec ships as a single LZA config PR — one PR, one merge, one LZA pipeline run, seven findings closed org-wide.

There are no manual prerequisites this time. Unlike Wave 1 PCI, this spec doesn't need a one-time SSM SecureString setup or a manual IAM unblock. The LZA pipeline is the only deployment mechanism.

## Tasks

### Pre-work

- [x] 1. Verify LZA TypeDoc shape for the `keyManagementService` block in v1.14.1
  - Confirmed against the LZA v1.14.1 source (`source/packages/@aws-accelerator/config/lib/security-config.ts` and `models/security-config.ts`):
    - Top-level field name in `security-config.yaml`: `keyManagementService` ✅
    - Position: at the **top level** of the file, NOT nested under `centralSecurityServices`.
    - Inner field for the list: `keySets` (NOT `keys`).
    - Per-key fields: `name` (required), `alias`, `policy` (NOT `policyFile`), `description`, `enableKeyRotation` (default `true`), `enabled` (default `true`), `removalPolicy` (default `retain`), `deploymentTargets`.
    - SSM Parameter Store path LZA publishes the key ARN to: confirmed during deployment via the AWS CLI in task 24; LZA's documented convention publishes per-key ARNs but the exact path will be verified post-deployment.
  - Design doc updated to reflect the actual schema.
  - _Requirements: 4.1, 4.3_

### CMK provisioning

- [x] 2. Author the CMK key policy file
  - Create `aws-accelerator-config/kms-policies/accelerator-s3-default-key-policy.json` with the JSON from design Component 1.
  - Statements: `AccountRootAdministration`, `AllowS3ServiceUseInThisAccount` (scoped via `kms:CallerAccount`), `AllowLogArchiveCrossAccountReadForAccessLogs`.
  - Use LZA replacement variables `${PARTITION}`, `${ACCOUNT_ID}`, `${LOG_ARCHIVE_ACCOUNT_ID}` per the project's existing convention.
  - Validate JSON: `python3 -m json.tool aws-accelerator-config/kms-policies/accelerator-s3-default-key-policy.json > /dev/null`
  - _Requirements: 4.2_
  - _Design: Component 1_

- [x] 3. Add the `keyManagementService` block to `security-config.yaml`
  - Insert at the **top level** of the file, alongside `centralSecurityServices`, `accessAnalyzer`, and `awsConfig` — NOT nested inside `centralSecurityServices`.
  - Use `keySets` (list of keys), not `keys`.
  - Use `policy:` (path to JSON), not `policyFile:`.
  - Single key entry: `name: AcceleratorS3DefaultKey`, `alias: alias/accelerator/s3-default`, `enableKeyRotation: true`, `enabled: true`, `removalPolicy: retain`, `policy: kms-policies/accelerator-s3-default-key-policy.json`, `deploymentTargets.organizationalUnits: [Root]`.
  - _Requirements: 4.1_
  - _Design: Component 1, Component 5_

### IAM remediation role policies

- [x] 4. Author `s3-ssl-requests-only-remediation-role.json`
  - Single statement allowing `s3:GetBucketPolicy`, `s3:PutBucketPolicy` on `arn:${PARTITION}:s3:::*`.
  - _Requirements: 2.5, 8.1_
  - _Design: Component 4_

- [x] 5. Author `s3-bucket-logging-remediation-role.json`
  - Single statement allowing `s3:GetBucketLogging`, `s3:PutBucketLogging` on `arn:${PARTITION}:s3:::*`.
  - _Requirements: 3.6, 8.1_
  - _Design: Component 4_

- [x] 6. Author `s3-lifecycle-remediation-role.json`
  - Allow `s3:GetBucketTagging`, `s3:GetLifecycleConfiguration`, `s3:PutLifecycleConfiguration` on `arn:${PARTITION}:s3:::*`.
  - The tag-read action is required for the opt-out branch in the SSM document.
  - _Requirements: 5.5, 8.1_
  - _Design: Component 4_

- [x] 7. Author `s3-bucket-kms-encryption-remediation-role.json`
  - Two statements: S3 encryption read/write on `arn:${PARTITION}:s3:::*`, and `ssm:GetParameter` scoped to `arn:${PARTITION}:ssm:*:*:parameter/accelerator/kms/AcceleratorS3DefaultKey/key-arn`.
  - No KMS actions on the role; the bucket calls KMS under its own account context.
  - _Requirements: 4.8, 8.1, 8.2_
  - _Design: Component 4_

- [x] 8. Author `sns-kms-encryption-remediation-role.json`
  - Single statement allowing `sns:GetTopicAttributes`, `sns:SetTopicAttributes` on `arn:${PARTITION}:sns:*:*:*`.
  - _Requirements: 6.5, 8.1_
  - _Design: Component 4_

- [x] 9. Author `cloudwatch-log-retention-remediation-role.json`
  - Single statement allowing `logs:DescribeLogGroups`, `logs:PutRetentionPolicy` on `arn:${PARTITION}:logs:*:*:log-group:*`.
  - _Requirements: 7.6, 8.1_
  - _Design: Component 4_

### Custom SSM Automation documents

- [x] 10. Author `enable-s3-bucket-logging.yaml`
  - Single `mainSteps` step: `aws:executeAwsApi` calling `s3:PutBucketLogging` with `BucketName`, `TargetBucket`, and a `TargetPrefix` of `s3-access-logs/{{ BucketName }}/`.
  - Parameters: `BucketName`, `TargetBucket`, `AutomationAssumeRole`.
  - _Requirements: 3.4_
  - _Design: Component 3, Document 1_

- [x] 11. Author `apply-default-s3-lifecycle.yaml`
  - Branching SSM document. Steps: `checkOptOutTag` (read bucket tags with `onFailure: Continue` so untagged buckets don't fail), `branchOnOptOut` (skip if tag = false), `skipBucket` (logs and ends), `applyLifecycle` (writes the lifecycle).
  - Lifecycle rule must NOT include `Expiration` or `NoncurrentVersionExpiration`. Only `Transitions` (90/180/365 → IA/Glacier/DeepArchive), `NoncurrentVersionTransitions` (30/90/180), `AbortIncompleteMultipartUpload.DaysAfterInitiation: 7`, `Filter.Prefix: ""`, `Status: Enabled`.
  - Parameters: `BucketName`, `AutomationAssumeRole`.
  - Test the YAML with `yq '.' aws-accelerator-config/ssm-documents/apply-default-s3-lifecycle.yaml > /dev/null` after authoring.
  - _Requirements: 5.3_
  - _Design: Component 3, Document 2_

- [x] 12. Author `enable-s3-bucket-kms-encryption.yaml`
  - Two steps: `getKmsKeyArn` (read SSM parameter `/accelerator/kms/AcceleratorS3DefaultKey/key-arn`), `enableEncryption` (call `s3:PutBucketEncryption` with `SSEAlgorithm: aws:kms`, `KMSMasterKeyID: {{ getKmsKeyArn.KeyArn }}`, `BucketKeyEnabled: true`).
  - Parameters: `BucketName`, `KmsKeyArnSsmPath` (default `/accelerator/kms/AcceleratorS3DefaultKey/key-arn`), `AutomationAssumeRole`.
  - _Requirements: 4.6, 4.7_
  - _Design: Component 3, Document 3_

### Wire SSM documents into LZA

- [x] 13. Add the three custom SSM documents to `ssmAutomation.documentSets`
  - Append three entries to the existing `ssmAutomation.documentSets[0].documents[]` array (the one with `shareTargets.organizationalUnits: [Root]`).
  - Names: `{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-Logging`, `{{ AcceleratorPrefix }}-SSM-Apply-Default-S3-Lifecycle`, `{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-KMS-Encryption`.
  - Templates point at the three new files in `ssm-documents/`.
  - Do NOT modify the existing two entries.
  - _Requirements: 1.2, 1.3_
  - _Design: Component 5_

### Config rules

Add the seven new rules to the existing `awsConfig.ruleSets[0].rules[]` array (deployment target `Root`). Append after the existing rules; do not reorder existing entries.

- [x] 14. Add the `S3.5` rule (`s3-bucket-ssl-requests-only`)
  - `identifier: S3_BUCKET_SSL_REQUESTS_ONLY`, `complianceResourceTypes: [AWS::S3::Bucket]`.
  - Remediation: `automatic: true`, `targetId: AWSConfigRemediation-RestrictBucketSSLRequestsOnly`, `targetVersion: "1"`, `retryAttemptSeconds: 60`, `maximumAutomaticAttempts: 5`.
  - Parameters: `BucketName` ← `RESOURCE_ID`, `AutomationAssumeRole` ← per-rule remediation role ARN.
  - `rolePolicyFile: ssm-remediation-roles/s3-ssl-requests-only-remediation-role.json`.
  - _Requirements: 2.1-2.5_
  - _Design: Component 2, Rule 1_

- [x] 15. Add the `S3.9` rule (`s3-bucket-logging-enabled`)
  - `identifier: S3_BUCKET_LOGGING_ENABLED`, `complianceResourceTypes: [AWS::S3::Bucket]`.
  - Remediation `targetId: {{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-Logging` (custom doc).
  - Parameters include `TargetBucket: ${ACCEL_LOOKUP::Bucket:s3AccessLogs}`.
  - `rolePolicyFile: ssm-remediation-roles/s3-bucket-logging-remediation-role.json`.
  - _Requirements: 3.1-3.6_
  - _Design: Component 2, Rule 2_

- [x] 16. Add the `S3.10` + `S3.13` rule (`s3-lifecycle-policy-check`)
  - `identifier: S3_LIFECYCLE_POLICY_CHECK`, `complianceResourceTypes: [AWS::S3::Bucket]`.
  - Remediation `targetId: {{ AcceleratorPrefix }}-SSM-Apply-Default-S3-Lifecycle` (custom doc).
  - Parameters: `BucketName` ← `RESOURCE_ID`, `AutomationAssumeRole`.
  - `rolePolicyFile: ssm-remediation-roles/s3-lifecycle-remediation-role.json`.
  - _Requirements: 5.1-5.6_
  - _Design: Component 2, Rule 3_

- [x] 17. Add the `S3.17` rule (`s3-default-encryption-kms`)
  - `identifier: S3_DEFAULT_ENCRYPTION_KMS`, `complianceResourceTypes: [AWS::S3::Bucket]`.
  - Remediation `targetId: {{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-KMS-Encryption` (custom doc).
  - Parameters: `BucketName` ← `RESOURCE_ID`, `KmsKeyArnSsmPath: /accelerator/kms/AcceleratorS3DefaultKey/key-arn`, `AutomationAssumeRole`.
  - `rolePolicyFile: ssm-remediation-roles/s3-bucket-kms-encryption-remediation-role.json`.
  - _Requirements: 4.4-4.8_
  - _Design: Component 2, Rule 4_

- [x] 18. Add the `SNS.1` rule (`sns-encrypted-kms`)
  - `identifier: SNS_ENCRYPTED_KMS`, `complianceResourceTypes: [AWS::SNS::Topic]`.
  - Remediation `targetId: AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic`, `targetVersion: "1"`.
  - Parameters: `TopicArn` ← `RESOURCE_ID`, `KmsKeyArn: alias/aws/sns`, `AutomationAssumeRole`.
  - `rolePolicyFile: ssm-remediation-roles/sns-kms-encryption-remediation-role.json`.
  - _Requirements: 6.1-6.5_
  - _Design: Component 2, Rule 5_

- [x] 19. Add the `CloudWatch.16` rule (`cw-loggroup-retention-period-check`)
  - `identifier: CW_LOGGROUP_RETENTION_PERIOD_CHECK`, `complianceResourceTypes: [AWS::Logs::LogGroup]`.
  - `inputParameters: { MinRetentionTime: "365" }`.
  - Remediation `targetId: AWS-UpdateCloudWatchLogGroupRetention`, `targetVersion: "1"`.
  - Parameters: `LogGroupName` ← `RESOURCE_ID`, `RetentionInDays: "365"`, `AutomationAssumeRole`.
  - `rolePolicyFile: ssm-remediation-roles/cloudwatch-log-retention-remediation-role.json`.
  - _Requirements: 7.1-7.6_
  - _Design: Component 2, Rule 6_

### Pre-merge validation

- [x] 20. Validate JSON and YAML
  - `python3 -m json.tool` on every new JSON file under `ssm-remediation-roles/` and `kms-policies/`.
  - `yq '.' <file>` on every new YAML file under `ssm-documents/` and on `security-config.yaml`.
  - Confirm `git diff --stat` shows only the expected paths (`security-config.yaml`, `kms-policies/`, `ssm-documents/`, `ssm-remediation-roles/`).
  - _Requirements: 1.4, 14.4_

### PR and merge

- [ ] 21. Open the PR
  - Branch: `feat/lza-config-rules-ssm-remediations`.
  - Title: `feat(lza): config rules + SSM auto-remediations for S3, SNS, CloudWatch`.
  - PR description summarizes which findings close, links the spec, and lists the post-merge LZA pipeline trigger as the deployment step.
  - Note that this PR does NOT trigger the GitHub Actions terraform workflow (paths filter excludes `aws-accelerator-config/`).
  - _Requirements: 1.5, 14.4_

- [ ] 22. Review and merge
  - Reviewer confirms the diff is additive only — no existing rules/docs/policies are modified.
  - Reviewer confirms the lifecycle YAML has no `Expiration` and no `NoncurrentVersionExpiration`.
  - Reviewer confirms each `rolePolicyFile` JSON has no service-level wildcards.
  - Squash merge to `main`.

### Deployment

- [ ] 23. Trigger the LZA pipeline
  - Sign in to the management account → CodePipeline → `AWSAccelerator-Pipeline` → **Release change**.
  - Pipeline run takes ~30 minutes.
  - Watch `Validate` and `Build` stages — failures here mean the YAML/JSON is malformed.
  - Watch `Deploy` stage — this is where the new resources actually land.

### Post-deployment verification

- [ ] 24. Verify CMK provisioned in PCI
  - From PCI account CloudShell:
    ```bash
    aws kms describe-key --key-id alias/accelerator/s3-default --region us-east-2 --query '{Arn:KeyMetadata.Arn, Rotation:KeyMetadata.KeyRotationStatus}'
    aws ssm get-parameter --name /accelerator/kms/AcceleratorS3DefaultKey/key-arn --region us-east-2 --query 'Parameter.Value' --output text
    ```
  - Expected: a CMK ARN, rotation enabled, the SSM parameter value matches the key ARN.
  - Repeat in `us-east-1` and `us-west-2`.
  - _Requirements: 11.1, 11.2_

- [ ] 25. Verify Config rules evaluating in PCI
  - AWS Config console (PCI account, each region).
  - Filter rules by tag `Accelerator = AWSAccelerator`.
  - Confirm all seven new rules listed.
  - For each rule, confirm a non-zero `EvaluatedResources` count.
  - Confirm at least one resource per rule transitions from `NON_COMPLIANT` to `COMPLIANT` within `retryAttemptSeconds × maximumAutomaticAttempts` (5 minutes max).
  - _Requirements: 11.1, 11.2_

- [ ] 26. Verify Security Hub findings flip to PASSED
  - Wait one Security Hub aggregation cycle (~1 hour).
  - In Audit account, run:
    ```bash
    aws securityhub get-findings \
      --filters '{"AwsAccountId":[{"Value":"247514667218","Comparison":"EQUALS"}], "ComplianceStatus":[{"Value":"PASSED","Comparison":"EQUALS"}]}' \
      --max-results 100 \
      --query 'Findings[?contains([`S3.5`,`S3.9`,`S3.10`,`S3.13`,`S3.17`,`SNS.1`,`CloudWatch.16`], ProductFields.ControlId)].{Control:ProductFields.ControlId, Status:Compliance.Status}'
    ```
  - Expected: all seven controls show `PASSED` for PCI.
  - _Requirements: 11.3_

- [ ] 27. Negative test — opt-out tag works
  - Pick one test bucket in any spoke account.
  - Apply tag: `accelerator:s3-lifecycle-managed = false`.
  - Wait for next AWS Config evaluation cycle (~5 minutes).
  - In AWS Config: confirm bucket reported `NON_COMPLIANT` by `s3-lifecycle-policy-check`.
  - In Systems Manager → Automation → Executions: confirm the remediation execution started, branched to `skipBucket`, ended without applying the lifecycle.
  - In S3 console: confirm the bucket's lifecycle configuration is unchanged.
  - _Requirements: 5.4, 13.3_

- [ ] 28. Cross-account verification
  - Repeat task 25 (AWS Config console check) for `Production`, `Development`, and one Infrastructure account (`Network`, `Perimeter`, or `SharedServices`).
  - Confirm the same seven rules are present and evaluating.
  - This verifies `Root` deployment works as designed, no per-account work needed.
  - _Requirements: 12.1, 12.3_

### Strategy bookkeeping

- [ ] 29. Capture compliance evidence
  - For tasks 24–28, save AWS CLI output and Console screenshots.
  - Store in the same evidence location as Wave 1 (referenced from parent strategy spec).
  - _Requirements: 11.4_

- [ ] 30. Update parent strategy disposition table
  - In `.kiro/specs/security-hub-findings-remediation-strategy/design.md`, mark rows for `S3.5`, `S3.9`, `S3.10`, `S3.13`, `S3.17`, `SNS.1`, `CloudWatch.16` as **Wave 1/2 complete via Config-Rule-SSM** with the date and evidence path.
  - Update mechanism count summary if it shifts.

## Task Dependency Graph

```json
{
  "waves": [
    {
      "wave": 1,
      "name": "Verify LZA TypeDoc shape",
      "tasks": [1],
      "depends_on": [],
      "parallel": false
    },
    {
      "wave": 2,
      "name": "CMK key policy + LZA block",
      "tasks": [2, 3],
      "depends_on": [1],
      "parallel": false
    },
    {
      "wave": 3,
      "name": "IAM remediation role policies",
      "tasks": [4, 5, 6, 7, 8, 9],
      "depends_on": [],
      "parallel": true
    },
    {
      "wave": 4,
      "name": "Custom SSM Automation documents",
      "tasks": [10, 11, 12],
      "depends_on": [],
      "parallel": true
    },
    {
      "wave": 5,
      "name": "Wire SSM documents into LZA",
      "tasks": [13],
      "depends_on": [10, 11, 12],
      "parallel": false
    },
    {
      "wave": 6,
      "name": "Config rules added to security-config.yaml",
      "tasks": [14, 15, 16, 17, 18, 19],
      "depends_on": [3, 4, 5, 6, 7, 8, 9, 13],
      "parallel": true
    },
    {
      "wave": 7,
      "name": "Pre-merge validation",
      "tasks": [20],
      "depends_on": [14, 15, 16, 17, 18, 19],
      "parallel": false
    },
    {
      "wave": 8,
      "name": "PR open + review + merge",
      "tasks": [21, 22],
      "depends_on": [20],
      "parallel": false
    },
    {
      "wave": 9,
      "name": "Trigger LZA pipeline (manual)",
      "tasks": [23],
      "depends_on": [22],
      "parallel": false
    },
    {
      "wave": 10,
      "name": "Post-deploy verification",
      "tasks": [24, 25, 26, 27, 28],
      "depends_on": [23],
      "parallel": false
    },
    {
      "wave": 11,
      "name": "Bookkeeping",
      "tasks": [29, 30],
      "depends_on": [28],
      "parallel": true
    }
  ]
}
```

Visual reference (for humans):

```
1 (verify TypeDoc shape)
    │
    ▼
2 (key policy file) ─► 3 (keyManagementService block)
                              │
                              │  (independent — these can start in parallel with 2/3)
                              │
4 (s3-ssl role)               │
5 (s3-logging role)           │
6 (s3-lifecycle role)         │  (parallel with 10-12)
7 (s3-kms role)  ◄────────────┤
8 (sns role)                  │
9 (cw-retention role)         │
                              │
10 (enable-s3-bucket-logging.yaml)
11 (apply-default-s3-lifecycle.yaml)
12 (enable-s3-bucket-kms-encryption.yaml)
                              │
                              ▼
                             13 (wire docs into ssmAutomation)
                              │
                              ▼
                       ┌─────────────┐
                       │14 S3.5      │
                       │15 S3.9      │
                       │16 S3.10/13  │  parallel
                       │17 S3.17     │
                       │18 SNS.1     │
                       │19 CW.16     │
                       └─────────────┘
                              │
                              ▼
                            20 (validate)
                              │
                              ▼
                            21 (PR) ──► 22 (merge)
                              │
                              ▼
                            23 (trigger LZA pipeline) ◄── manual, ~30min
                              │
                              ▼
                            24 (KMS verify)
                            25 (Config console verify)
                            26 (Security Hub verify) ◄── after ~1hr aggregation
                            27 (negative tag-opt-out test)
                            28 (cross-account verify)
                              │
                              ▼
                            29 (evidence capture)
                            30 (strategy bookkeeping)
```

Critical path: 1 → 2 → 3 → 13 → 14-19 (parallel) → 20 → 21 → 22 → 23 → 24-28 → 29/30.

Tasks 4-9 (IAM roles) and 10-12 (SSM docs) are independent of the CMK chain and can be done in parallel.

## Notes

### How this maps to your existing CI

Unlike the security-baseline Wave 1 PR, this PR does **not** touch `terraform/`. The GitHub Actions `terraform.yml` workflow has a `paths` filter that excludes `aws-accelerator-config/`, so terraform.yml will not run on this PR. That's expected.

The **LZA pipeline** is the only deployment system that consumes this PR. It runs in AWS CodePipeline in the management account and is triggered manually via "Release change" in the Console. There's no `gh workflow run` equivalent.

### Does this PR affect existing buckets, topics, log groups?

Yes. After the LZA pipeline runs, AWS Config evaluates every existing in-scope resource and triggers remediation on every non-compliant one. Expect bucket policies to be modified (S3.5), bucket lifecycle to be applied (S3.10/13), bucket encryption to flip to SSE-KMS (S3.17), SNS topic encryption to flip to alias/aws/sns (SNS.1), and CloudWatch log group retention to be set to 365 days (CloudWatch.16) on every existing resource not already compliant.

Buckets that already comply are reported `COMPLIANT` and unchanged.

If a bucket has an existing lifecycle that you want to preserve, **tag it with `accelerator:s3-lifecycle-managed = false` BEFORE running the LZA pipeline**. The opt-out check fires per evaluation cycle, so any bucket tagged before the first evaluation is safe.

### Rollback if a remediation misfires

Per the design doc's Error Handling section:
- **Per-rule, slow:** edit `security-config.yaml`, set the offending rule's `remediation.automatic` to `false`, run LZA pipeline. Detection continues; remediation stops.
- **Whole-rule, faster:** delete the rule entry from `security-config.yaml`, run LZA. AWS Config marks the rule as deleted.
- **Resource-by-resource:** undo the bad remediation manually (e.g., `aws s3api delete-bucket-policy`).

### Existing buckets with existing CMK encryption

If a bucket is already SSE-KMS encrypted with a different CMK, it is `COMPLIANT` for `S3_DEFAULT_ENCRYPTION_KMS` and the rule does NOT replace the existing key with the Accelerator default. Only buckets without KMS encryption (or with SSE-S3 only) are remediated.

### What follows this spec

Once Wave 2 of the parent strategy is fully addressed, the remaining specs to spawn:

1. **`lza-vpc-endpoints-pci-coverage`** — investigate and close `EC2.10/55/56/57/58/60` on the PCI VPC. Investigation-first.
2. **`lza-iam-and-account-baseline`** — close `IAM.18` (support role).
3. (Optional) **`scp-preventive-controls-for-service-settings`** — add SCPs that prevent disabling Inspector, EBS public block, SSM public sharing once enabled. Converts Wave 1 fixes into permanent guardrails.
