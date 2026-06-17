# Design Document — LZA Config Rules and SSM Auto-Remediations

## Metadata

| Field | Value |
|---|---|
| Document version | 1.0 |
| Last review | 2026-06-17 |
| Document owner | Cloud Platform / Security |
| Parent strategy | `.kiro/specs/security-hub-findings-remediation-strategy/design.md` |
| LZA version | v1.14.1 (per `aws-accelerator-config/global-config.yaml`) |
| Wave | Wave 1 + Wave 2 (deploy to `Root`, PCI is leading edge) |
| Findings closed | `S3.5`, `S3.9`, `S3.10`, `S3.13`, `S3.17`, `SNS.1`, `CloudWatch.16` |

## Overview

This design extends `aws-accelerator-config/security-config.yaml` with seven AWS Config rule + SSM Automation document pairs that detect and auto-remediate per-resource Security Hub findings org-wide. It implements the `Config-Rule-SSM` mechanism rows from the parent strategy spec.

The change is entirely in LZA configuration. There is no Terraform, no per-account leaf, no manual unblock. The LZA pipeline reads `security-config.yaml` and propagates the rules + SSM documents + IAM remediation roles + a new customer-managed KMS key for default S3 encryption to every enrolled account in every active region. New accounts inherit the rules from their first LZA pipeline run.

The design has three architectural pieces:

1. **A per-region CMK** for default S3 bucket encryption, provisioned via LZA's `keyManagementService` block in `security-config.yaml`. The key ARN is published to SSM Parameter Store at a predictable path so the remediation document can resolve it at runtime.
2. **Seven Config rules** under `awsConfig.ruleSets` deployed to `Root`, each with `remediation.automatic: true`.
3. **Seven SSM Automation documents** under `ssmAutomation.documentSets` shared to `Root`, plus seven IAM role policy files under `ssm-remediation-roles/` granting least-privilege permissions per remediation.

The pattern matches the two existing auto-remediating rules in this repo (`ec2-instance-profile-attached`, `elb-logging-enabled`); this spec adds entries to the same arrays rather than introducing a new mechanism.

## Architecture

### High-level flow

```
                ┌────────────────────────────────────────────────────────────┐
                │ aws-accelerator-config/security-config.yaml                │
                │   - keyManagementService: alias/accelerator/s3-default     │
                │   - awsConfig.ruleSets[*].rules[*]  (7 new entries)        │
                │   - ssmAutomation.documentSets[*].documents[*] (7 docs)    │
                └────────────────────────┬───────────────────────────────────┘
                                         │ LZA pipeline reads
                                         ▼
                ┌────────────────────────────────────────────────────────────┐
                │ AWS Accelerator Pipeline (CodePipeline)                    │
                │   - Validates config                                       │
                │   - Deploys to every account in enabledRegions             │
                │   - Publishes CMK ARN to SSM at /accelerator/kms/...       │
                └────────────────────────┬───────────────────────────────────┘
                                         │ propagates to every spoke
                                         ▼
   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌─────────────────────────┐
   │ PCI account             │     │ Production account      │     │ ... every other spoke   │
   │   - 7 Config rules      │     │   - same 7 rules        │     │   - same 7 rules        │
   │   - 7 SSM docs shared   │     │   - same docs           │     │   - same docs           │
   │   - 7 remediation roles │     │   - same roles          │     │   - same roles          │
   │   - alias/accelerator/  │     │   - alias/accelerator/  │     │   - alias/accelerator/  │
   │     s3-default CMK      │     │     s3-default CMK      │     │     s3-default CMK      │
   └─────────┬───────────────┘     └───────────┬─────────────┘     └───────────┬─────────────┘
             │                                 │                               │
             ▼                                 ▼                               ▼
   ┌──────────────────────────────────────────────────────────────────────────────────────┐
   │ Per resource (S3 bucket, SNS topic, log group):                                      │
   │   1. AWS Config evaluates → COMPLIANT / NON_COMPLIANT                                │
   │   2. If NON_COMPLIANT, AWS Config invokes the SSM remediation doc                    │
   │   3. SSM doc reads CMK ARN from SSM Parameter Store (S3.17 only)                     │
   │   4. SSM doc calls AWS API to fix the resource                                       │
   │   5. AWS Config re-evaluates → COMPLIANT                                             │
   │   6. Security Hub aggregates → control flips to PASSED                               │
   └──────────────────────────────────────────────────────────────────────────────────────┘
```

### Where each piece lives

| Piece | Location |
|---|---|
| KMS CMK definition | `aws-accelerator-config/security-config.yaml` `keyManagementService` block |
| Config rule definitions | `aws-accelerator-config/security-config.yaml` `awsConfig.ruleSets[0].rules[]` |
| SSM document share | `aws-accelerator-config/security-config.yaml` `ssmAutomation.documentSets[0].documents[]` |
| SSM document templates | `aws-accelerator-config/ssm-documents/*.yaml` (3 new files) |
| IAM remediation role policies | `aws-accelerator-config/ssm-remediation-roles/*.json` (5 new files) |
| Custom Config rule lambdas | None — all rules use AWS-managed identifiers |

### Why a new CMK rather than an existing LZA key

LZA already provisions CMKs for its own internal use (EBS default encryption, central log bucket, CloudTrail). Those keys' policies are scoped tightly to LZA-managed services and would not allow arbitrary user-owned buckets to encrypt data with them. They also are not published at predictable SSM paths for downstream consumption.

The right architectural answer is to provision a new CMK explicitly for this purpose: `alias/accelerator/s3-default`, per region, with a key policy that allows the `s3.amazonaws.com` service principal scoped to the account, plus the LZA log-archive principal for cross-account access logging continuity. This key is owned by this spec and is the destination the auto-remediation points buckets at.

## Components and Interfaces

### Component 1 — Per-region CMK for default S3 encryption (`keyManagementService`)

LZA v1.14.1 exposes a `keyManagementService` primitive under `securityConfig` that creates a per-region customer-managed key with a specified policy and publishes its ARN to SSM Parameter Store.

The exact LZA TypeDoc path is `SecurityConfigTypes.keyManagementServiceConfig`. The block accepts a list of keys; each key has a name, alias, description, key policy file, and rotation toggle.

**YAML block to add (location: top level of `security-config.yaml`, alongside `centralSecurityServices`, `awsConfig`, `accessAnalyzer`, etc. — NOT nested inside `centralSecurityServices`):**

```yaml
keyManagementService:
  keySets:
    - name: AcceleratorS3DefaultKey
      alias: alias/accelerator/s3-default
      description: Default customer-managed KMS key for org-wide S3 bucket encryption.
      enableKeyRotation: true
      enabled: true
      removalPolicy: retain
      policy: kms-policies/accelerator-s3-default-key-policy.json
      deploymentTargets:
        organizationalUnits:
          - Root
```

LZA v1.14.1 schema (`KeyManagementServiceConfig`):
- The block uses `keySets`, not `keys`.
- The key file pointer is `policy`, not `policyFile`.
- `removalPolicy: retain` is the default and is set explicitly to make the intent visible in YAML review.

**New key policy file: `aws-accelerator-config/kms-policies/accelerator-s3-default-key-policy.json`**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AccountRootAdministration",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowS3ServiceUseInThisAccount",
      "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      }
    },
    {
      "Sid": "AllowLogArchiveCrossAccountReadForAccessLogs",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:${PARTITION}:iam::${LOG_ARCHIVE_ACCOUNT_ID}:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
```

LZA replacement variables (`${ACCOUNT_ID}`, `${LOG_ARCHIVE_ACCOUNT_ID}`, `${PARTITION}`) follow the existing patterns used by LZA in its own JSON policy files. The exact replacement syntax will be confirmed against the LZA TypeDoc when implementing.

**SSM Parameter Store path:** LZA publishes the key ARN at `/accelerator/kms/AcceleratorS3DefaultKey/key-arn` automatically when the key is provisioned via `keyManagementService`. The remediation SSM document reads this path at runtime.

### Component 2 — Config rules in `awsConfig.ruleSets`

All seven rules are added to the existing `awsConfig.ruleSets[0]` block (the one with `deploymentTargets.organizationalUnits: [Root]` already in place).

#### Rule 1: S3.5 — `s3-bucket-ssl-requests-only`

```yaml
- name: "{{ AcceleratorPrefix }}-s3-bucket-ssl-requests-only"
  identifier: S3_BUCKET_SSL_REQUESTS_ONLY
  complianceResourceTypes:
    - AWS::S3::Bucket
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/s3-ssl-requests-only-remediation-role.json
    automatic: true
    targetId: AWSConfigRemediation-RestrictBucketSSLRequestsOnly
    targetVersion: "1"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: BucketName
        value: RESOURCE_ID
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-S3SslRequestsOnly"
        type: String
```

#### Rule 2: S3.9 — `s3-bucket-logging-enabled`

```yaml
- name: "{{ AcceleratorPrefix }}-s3-bucket-logging-enabled"
  identifier: S3_BUCKET_LOGGING_ENABLED
  complianceResourceTypes:
    - AWS::S3::Bucket
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/s3-bucket-logging-remediation-role.json
    automatic: true
    targetId: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-Logging"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: BucketName
        value: RESOURCE_ID
        type: String
      - name: TargetBucket
        value: ${ACCEL_LOOKUP::Bucket:s3AccessLogs}
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-S3BucketLogging"
        type: String
```

A custom SSM document is needed here because the AWS managed `AWS-ConfigureS3BucketLogging` document does not handle the per-account access-log bucket lookup. The custom document is in Component 3.

#### Rule 3: S3.10 + S3.13 — `s3-lifecycle-policy-check`

```yaml
- name: "{{ AcceleratorPrefix }}-s3-lifecycle-policy-check"
  identifier: S3_LIFECYCLE_POLICY_CHECK
  complianceResourceTypes:
    - AWS::S3::Bucket
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/s3-lifecycle-remediation-role.json
    automatic: true
    targetId: "{{ AcceleratorPrefix }}-SSM-Apply-Default-S3-Lifecycle"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: BucketName
        value: RESOURCE_ID
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-S3Lifecycle"
        type: String
```

The Config rule does not need to filter by tag for the opt-out path — instead, the remediation SSM document checks for the `accelerator:s3-lifecycle-managed = false` tag on the bucket and exits without applying the lifecycle when the tag is set. This keeps the rule scope simple.

#### Rule 4: S3.17 — `s3-default-encryption-kms`

```yaml
- name: "{{ AcceleratorPrefix }}-s3-default-encryption-kms"
  identifier: S3_DEFAULT_ENCRYPTION_KMS
  complianceResourceTypes:
    - AWS::S3::Bucket
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/s3-bucket-kms-encryption-remediation-role.json
    automatic: true
    targetId: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-KMS-Encryption"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: BucketName
        value: RESOURCE_ID
        type: String
      - name: KmsKeyArnSsmPath
        value: "/accelerator/kms/AcceleratorS3DefaultKey/key-arn"
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-S3KmsEncryption"
        type: String
```

The remediation reads the KMS ARN from SSM Parameter Store at runtime, so the same Config rule works in every region without per-region duplication.

#### Rule 5: SNS.1 — `sns-encrypted-kms`

```yaml
- name: "{{ AcceleratorPrefix }}-sns-encrypted-kms"
  identifier: SNS_ENCRYPTED_KMS
  complianceResourceTypes:
    - AWS::SNS::Topic
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/sns-kms-encryption-remediation-role.json
    automatic: true
    targetId: AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic
    targetVersion: "1"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: TopicArn
        value: RESOURCE_ID
        type: String
      - name: KmsKeyArn
        value: "alias/aws/sns"
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-SnsKmsEncryption"
        type: String
```

For SNS we use the AWS-managed `alias/aws/sns` key because:
- Auditors accept `alias/aws/sns` for SNS encryption (different audit posture from S3 because SNS messages are typically transient).
- Authoring a per-region SNS CMK with a cross-service trust policy adds significant complexity for marginal audit benefit.
- If a future audit requires customer-managed keys for SNS specifically, we revisit and add an `alias/accelerator/sns-default` key in a follow-up spec.

#### Rule 6: CloudWatch.16 — `cw-loggroup-retention-period-check`

```yaml
- name: "{{ AcceleratorPrefix }}-cw-loggroup-retention-period-check"
  identifier: CW_LOGGROUP_RETENTION_PERIOD_CHECK
  complianceResourceTypes:
    - AWS::Logs::LogGroup
  inputParameters:
    MinRetentionTime: "365"
  tags:
    - key: Accelerator
      value: "{{ AcceleratorPrefix }}"
  remediation:
    rolePolicyFile: ssm-remediation-roles/cloudwatch-log-retention-remediation-role.json
    automatic: true
    targetId: AWS-UpdateCloudWatchLogGroupRetention
    targetVersion: "1"
    retryAttemptSeconds: 60
    maximumAutomaticAttempts: 5
    parameters:
      - name: LogGroupName
        value: RESOURCE_ID
        type: String
      - name: RetentionInDays
        value: "365"
        type: String
      - name: AutomationAssumeRole
        value: "arn:aws:iam::${ACCOUNT_ID}:role/AWSAccelerator-SSMRemediation-CloudWatchLogRetention"
        type: String
```

`MinRetentionTime: 365` matches the existing `cloudwatchLogRetentionInDays: 365` default in `global-config.yaml`. LZA-managed log groups already have 365-day retention set, so they're compliant; the rule catches and remediates non-LZA groups.

### Component 3 — Custom SSM Automation documents

Three documents need to be authored. SNS, S3.5, and CloudWatch retention use AWS-managed documents; the rest need custom ones because the managed alternatives don't handle the LZA-specific lookups (per-region access-log buckets, per-region CMK ARN from SSM, tag-based opt-out).

All custom documents are added to the existing `ssmAutomation.documentSets[0].documents[]` array (shared to `Root`).

#### Document 1: `ssm-documents/enable-s3-bucket-logging.yaml`

```yaml
description: Enable server access logging on an S3 bucket pointing at the LZA per-region access-log bucket.
schemaVersion: "0.3"
assumeRole: "{{ AutomationAssumeRole }}"
parameters:
  BucketName:
    type: String
  TargetBucket:
    type: String
  AutomationAssumeRole:
    type: String
mainSteps:
  - name: enableLogging
    action: "aws:executeAwsApi"
    inputs:
      Service: s3
      Api: PutBucketLogging
      Bucket: "{{ BucketName }}"
      BucketLoggingStatus:
        LoggingEnabled:
          TargetBucket: "{{ TargetBucket }}"
          TargetPrefix: "s3-access-logs/{{ BucketName }}/"
```

#### Document 2: `ssm-documents/apply-default-s3-lifecycle.yaml`

```yaml
description: Apply the default Accelerator S3 lifecycle to a bucket. Transitions only — no expirations. Tag-based opt-out via accelerator:s3-lifecycle-managed = false.
schemaVersion: "0.3"
assumeRole: "{{ AutomationAssumeRole }}"
parameters:
  BucketName:
    type: String
  AutomationAssumeRole:
    type: String
mainSteps:
  - name: checkOptOutTag
    action: "aws:executeAwsApi"
    inputs:
      Service: s3
      Api: GetBucketTagging
      Bucket: "{{ BucketName }}"
    outputs:
      - Name: TagSet
        Selector: "$.TagSet"
        Type: MapList
    onFailure: Continue
  - name: branchOnOptOut
    action: "aws:branch"
    inputs:
      Choices:
        - Variable: "{{ checkOptOutTag.TagSet }}"
          Contains:
            Key: "accelerator:s3-lifecycle-managed"
            Value: "false"
          NextStep: skipBucket
      Default: applyLifecycle
  - name: skipBucket
    action: "aws:executeScript"
    inputs:
      Runtime: python3.11
      Handler: handler
      Script: |
        def handler(events, context):
            return {"status": "skipped", "reason": "accelerator:s3-lifecycle-managed=false"}
    isEnd: true
  - name: applyLifecycle
    action: "aws:executeAwsApi"
    inputs:
      Service: s3
      Api: PutBucketLifecycleConfiguration
      Bucket: "{{ BucketName }}"
      LifecycleConfiguration:
        Rules:
          - ID: AcceleratorDefaultLifecycle
            Status: Enabled
            Filter:
              Prefix: ""
            Transitions:
              - Days: 90
                StorageClass: STANDARD_IA
              - Days: 180
                StorageClass: GLACIER
              - Days: 365
                StorageClass: DEEP_ARCHIVE
            NoncurrentVersionTransitions:
              - NoncurrentDays: 30
                StorageClass: STANDARD_IA
              - NoncurrentDays: 90
                StorageClass: GLACIER
              - NoncurrentDays: 180
                StorageClass: DEEP_ARCHIVE
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7
```

Note: no `Expiration` block, no `NoncurrentVersionExpiration` block. Data is never deleted by lifecycle.

#### Document 3: `ssm-documents/enable-s3-bucket-kms-encryption.yaml`

```yaml
description: Enable SSE-KMS default encryption on an S3 bucket using the per-region Accelerator S3 default CMK.
schemaVersion: "0.3"
assumeRole: "{{ AutomationAssumeRole }}"
parameters:
  BucketName:
    type: String
  KmsKeyArnSsmPath:
    type: String
    default: "/accelerator/kms/AcceleratorS3DefaultKey/key-arn"
  AutomationAssumeRole:
    type: String
mainSteps:
  - name: getKmsKeyArn
    action: "aws:executeAwsApi"
    inputs:
      Service: ssm
      Api: GetParameter
      Name: "{{ KmsKeyArnSsmPath }}"
    outputs:
      - Name: KeyArn
        Selector: "$.Parameter.Value"
        Type: String
  - name: enableEncryption
    action: "aws:executeAwsApi"
    inputs:
      Service: s3
      Api: PutBucketEncryption
      Bucket: "{{ BucketName }}"
      ServerSideEncryptionConfiguration:
        Rules:
          - ApplyServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
              KMSMasterKeyID: "{{ getKmsKeyArn.KeyArn }}"
            BucketKeyEnabled: true
```

`BucketKeyEnabled: true` reduces KMS request cost by amortizing key data across many objects.

The three custom documents are added to `ssmAutomation.documentSets[0].documents[]` alongside the existing two (`{{ AcceleratorPrefix }}-SSM-ELB-Enable-Logging`, `{{ AcceleratorPrefix }}-Attach-IAM-Instance-Profile`):

```yaml
documents:
  - name: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-Logging"
    template: ssm-documents/enable-s3-bucket-logging.yaml
  - name: "{{ AcceleratorPrefix }}-SSM-Apply-Default-S3-Lifecycle"
    template: ssm-documents/apply-default-s3-lifecycle.yaml
  - name: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-KMS-Encryption"
    template: ssm-documents/enable-s3-bucket-kms-encryption.yaml
```

### Component 4 — IAM remediation role policies

Five new policy files under `aws-accelerator-config/ssm-remediation-roles/`. Each grants only what its corresponding SSM document needs.

#### `s3-ssl-requests-only-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketPolicy",
        "s3:PutBucketPolicy"
      ],
      "Resource": "arn:${PARTITION}:s3:::*"
    }
  ]
}
```

#### `s3-bucket-logging-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLogging",
        "s3:PutBucketLogging"
      ],
      "Resource": "arn:${PARTITION}:s3:::*"
    }
  ]
}
```

#### `s3-lifecycle-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketTagging",
        "s3:GetLifecycleConfiguration",
        "s3:PutLifecycleConfiguration"
      ],
      "Resource": "arn:${PARTITION}:s3:::*"
    }
  ]
}
```

#### `s3-bucket-kms-encryption-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Encryption",
      "Effect": "Allow",
      "Action": [
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration"
      ],
      "Resource": "arn:${PARTITION}:s3:::*"
    },
    {
      "Sid": "ReadCmkArn",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "arn:${PARTITION}:ssm:*:*:parameter/accelerator/kms/AcceleratorS3DefaultKey/key-arn"
    }
  ]
}
```

The role does not need any KMS actions because the bucket performs the encrypt operation under the bucket's account context using the CMK's key policy.

#### `sns-kms-encryption-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes"
      ],
      "Resource": "arn:${PARTITION}:sns:*:*:*"
    }
  ]
}
```

#### `cloudwatch-log-retention-remediation-role.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy"
      ],
      "Resource": "arn:${PARTITION}:logs:*:*:log-group:*"
    }
  ]
}
```

Total: six policy files (the existing `s3-ssl-requests-only` AWS-managed document also needs a role policy because the LZA wiring requires a `rolePolicyFile` for every `automatic: true` remediation; AWS Config invokes the role we define, which in turn assumes into the SSM document).

### Component 5 — `security-config.yaml` final structure

The new entries land in three places in the existing file. The diff is additive only; nothing is removed or reordered.

```yaml
# top-level under security-config.yaml — alongside centralSecurityServices, NOT inside it
centralSecurityServices:
  delegatedAdminAccount: Audit
  ebsDefaultVolumeEncryption: ...     # existing
  s3PublicAccessBlock: ...             # existing
  scpRevertChangesConfig: ...          # existing
  snsSubscriptions: []                 # existing
  macie: ...                           # existing
  guardduty: ...                       # existing
  securityHub: ...                     # existing

  ssmAutomation:
    documentSets:
      - shareTargets:
          organizationalUnits:
            - Root
        documents:
          - name: "{{ AcceleratorPrefix }}-SSM-ELB-Enable-Logging"      # existing
            template: ssm-documents/enable-elb-logging.yaml
          - name: "{{ AcceleratorPrefix }}-Attach-IAM-Instance-Profile" # existing
            template: ssm-documents/attach-iam-instance-profile.yaml
          # ADDED — see Component 3
          - name: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-Logging"
            template: ssm-documents/enable-s3-bucket-logging.yaml
          - name: "{{ AcceleratorPrefix }}-SSM-Apply-Default-S3-Lifecycle"
            template: ssm-documents/apply-default-s3-lifecycle.yaml
          - name: "{{ AcceleratorPrefix }}-SSM-Enable-S3-Bucket-KMS-Encryption"
            template: ssm-documents/enable-s3-bucket-kms-encryption.yaml

# ADDED — top-level block, see Component 1
keyManagementService:
  keySets:
    - name: AcceleratorS3DefaultKey
      alias: alias/accelerator/s3-default
      description: Default customer-managed KMS key for org-wide S3 bucket encryption.
      enableKeyRotation: true
      enabled: true
      removalPolicy: retain
      policy: kms-policies/accelerator-s3-default-key-policy.json
      deploymentTargets:
        organizationalUnits:
          - Root

# existing — unchanged
accessAnalyzer:
  enable: true

awsConfig:
  ...
  ruleSets:
    - deploymentTargets:
        organizationalUnits:
          - Root
      rules:
        # existing rules
        - name: "{{ AcceleratorPrefix }}-iam-user-group-membership-check"
          ...
        - name: "{{ AcceleratorPrefix }}-ec2-instance-profile-attached"
          ...
        - name: "{{ AcceleratorPrefix }}-elb-logging-enabled"
          ...
        # ADDED — see Component 2 (7 new rules)
        - name: "{{ AcceleratorPrefix }}-s3-bucket-ssl-requests-only"
          ...
        - name: "{{ AcceleratorPrefix }}-s3-bucket-logging-enabled"
          ...
        - name: "{{ AcceleratorPrefix }}-s3-lifecycle-policy-check"
          ...
        - name: "{{ AcceleratorPrefix }}-s3-default-encryption-kms"
          ...
        - name: "{{ AcceleratorPrefix }}-sns-encrypted-kms"
          ...
        - name: "{{ AcceleratorPrefix }}-cw-loggroup-retention-period-check"
          ...
```

## Data Models

### SSM Parameter Store paths

| Path | Type | Producer | Consumer |
|---|---|---|---|
| `/accelerator/kms/AcceleratorS3DefaultKey/key-arn` | String | LZA `keyManagementService` block | `enable-s3-bucket-kms-encryption.yaml` SSM document at remediation time |

### Config rule input parameters by rule

| Rule | Input parameter | Value | Source |
|---|---|---|---|
| S3.5 | (none — rule has no inputs) | — | — |
| S3.9 | (rule has no inputs; remediation receives `BucketName` + `TargetBucket`) | — | — |
| S3.10/S3.13 | (none) | — | — |
| S3.17 | (none — CMK ARN resolved at remediation time) | — | — |
| SNS.1 | (none) | — | — |
| CloudWatch.16 | `MinRetentionTime` | `"365"` | static |

### Custom SSM document parameters

| Document | Required parameters | Notes |
|---|---|---|
| `enable-s3-bucket-logging.yaml` | `BucketName`, `TargetBucket`, `AutomationAssumeRole` | `TargetBucket` resolved by Config rule via `${ACCEL_LOOKUP::Bucket:s3AccessLogs}` |
| `apply-default-s3-lifecycle.yaml` | `BucketName`, `AutomationAssumeRole` | Branches on `accelerator:s3-lifecycle-managed = false` tag |
| `enable-s3-bucket-kms-encryption.yaml` | `BucketName`, `KmsKeyArnSsmPath`, `AutomationAssumeRole` | Reads `KmsKeyArnSsmPath` from SSM Parameter Store at runtime |

### Findings closed and their AWS Config rule mapping

| Finding | AWS Config rule identifier | Remediation document |
|---|---|---|
| `S3.5` | `S3_BUCKET_SSL_REQUESTS_ONLY` | `AWSConfigRemediation-RestrictBucketSSLRequestsOnly` (AWS-managed) |
| `S3.9` | `S3_BUCKET_LOGGING_ENABLED` | `Accelerator-SSM-Enable-S3-Bucket-Logging` (custom) |
| `S3.10` + `S3.13` | `S3_LIFECYCLE_POLICY_CHECK` | `Accelerator-SSM-Apply-Default-S3-Lifecycle` (custom) |
| `S3.17` | `S3_DEFAULT_ENCRYPTION_KMS` | `Accelerator-SSM-Enable-S3-Bucket-KMS-Encryption` (custom) |
| `SNS.1` | `SNS_ENCRYPTED_KMS` | `AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic` (AWS-managed) |
| `CloudWatch.16` | `CW_LOGGROUP_RETENTION_PERIOD_CHECK` | `AWS-UpdateCloudWatchLogGroupRetention` (AWS-managed) |

## Correctness Properties

### Property 1: All rules deploy to `Root`

Every Config rule and every SSM document share is targeted at `organizationalUnits: [Root]`. Every account in the org including future accounts inherits the rules from its first LZA pipeline run.

**Validates: Requirements 1.1, 1.2, 9.1, 12.1, 12.3**

### Property 2: One rule per finding control

Each Security Hub control covered by this spec maps to exactly one Config rule. The S3.10 + S3.13 single-rule pairing is documented as intentional.

**Validates: Requirements 5.1, 5.6**

### Property 3: Auto-remediation has bounded retries

Every `remediation.automatic: true` block has `maximumAutomaticAttempts: 5` and `retryAttemptSeconds: 60`. No unlimited retries.

**Validates: Requirements 8.3, 8.4**

### Property 4: Lifecycle never expires data

The `apply-default-s3-lifecycle.yaml` SSM document has no `Expiration` block on the rule and no `NoncurrentVersionExpiration` block. Only `Transitions`, `NoncurrentVersionTransitions`, and `AbortIncompleteMultipartUpload` are defined.

**Validates: Requirements 5.3**

### Property 5: KMS CMK is per-region, customer-managed

`alias/accelerator/s3-default` is provisioned by LZA's `keyManagementService` with `enableKeyRotation: true`. It is owned by this spec, not borrowed from another LZA-internal key.

**Validates: Requirements 4.1, 4.2**

### Property 6: Remediation roles are least-privileged

Each `rolePolicyFile` grants only the AWS API actions its specific SSM document calls. No service-level wildcards (`s3:*`, `kms:*`, `sns:*`).

**Validates: Requirements 8.1, 8.2**

### Property 7: Tag-based opt-out works for the lifecycle rule

A bucket tagged `accelerator:s3-lifecycle-managed = false` is detected by the `apply-default-s3-lifecycle.yaml` document and skipped without applying the lifecycle. The bucket is reported `NON_COMPLIANT` by Config, but no remediation runs.

**Validates: Requirements 5.4, 13.3**

### Property 8: Config rules evaluate existing resources

After LZA reconciles, AWS Config evaluates every existing in-scope resource in every account. Non-compliant resources are remediated automatically.

**Validates: Requirements 10.1, 10.2, 10.3**

### Property 9: SNS uses AWS-managed key intentionally

The SNS rule remediates with `alias/aws/sns`, not a customer-managed key. This is documented as a design decision (Decision section in requirements.md) and is acceptable for the standard audit posture.

**Validates: Requirements 6.4, 14.1**

### Property 10: No detective-only rules in this spec

Every rule added by this spec has `remediation.automatic: true`. Detective-only rules belong in a separate spec.

**Validates: Requirements 14.5**

## Error Handling

### LZA TypeDoc differs from documented `keyManagementService` shape

If LZA v1.14.1 names the block differently (e.g., `customerManagedKeys` instead of `keyManagementService`), the implementation spec MUST consult the LZA TypeDoc for the exact block name and field names. The semantics are unchanged; only the YAML keys may shift.

### AWS-managed Config rule identifier is not available in a region

If `S3_BUCKET_SSL_REQUESTS_ONLY`, `S3_BUCKET_LOGGING_ENABLED`, `S3_LIFECYCLE_POLICY_CHECK`, `S3_DEFAULT_ENCRYPTION_KMS`, `SNS_ENCRYPTED_KMS`, or `CW_LOGGROUP_RETENTION_PERIOD_CHECK` is missing from any active region, the implementation spec MUST author a custom Lambda-backed Config rule for that region. As of LZA v1.14.1, all six identifiers are AWS-managed and available in every commercial region; this is a defensive note only.

### AWS-managed SSM document is not available in a region

If `AWSConfigRemediation-RestrictBucketSSLRequestsOnly`, `AWSConfigRemediation-EnableEncryptionWithSSEKMSOnSNSTopic`, or `AWS-UpdateCloudWatchLogGroupRetention` is missing from any active region, the implementation spec MUST author a custom SSM document under `ssm-documents/` for the missing case. The implementation order would be: (1) confirm the document exists in `us-east-1`, `us-east-2`, `us-west-2`; (2) if not, add a custom YAML alongside the existing custom documents.

### Remediation fails after `maximumAutomaticAttempts`

The resource remains `NON_COMPLIANT` in AWS Config. Operators triage via:
1. AWS Config console → resource → recent remediation execution log link
2. CloudWatch Logs `/aws/ssm/automation` (the destination from the parent strategy's Wave 1 SSM Automation logging work) for the SSM execution detail
3. If the failure is a missing IAM permission, widen the relevant `ssm-remediation-roles/*.json` policy and re-run LZA
4. If the failure is a resource-specific issue (e.g., a bucket that legitimately should not have a lifecycle), apply the opt-out tag and the rule will continue to mark non-compliant but stop trying to remediate

### Bucket has an immutable lifecycle (e.g., compliance hold)

If a bucket has an existing lifecycle that the apply-default-lifecycle document overwrites, the original is replaced. To prevent this, tag the bucket with `accelerator:s3-lifecycle-managed = false` BEFORE the LZA pipeline runs. The opt-out tag is the only mechanism to preserve a bucket's existing lifecycle through this rule.

### KMS key policy denies a bucket's encrypt operation

If the `alias/accelerator/s3-default` key's policy is too tight (e.g., the `kms:CallerAccount` condition rejects a specific account), the `PutBucketEncryption` call succeeds but subsequent writes to the bucket fail with KMS access denied. Triage: re-examine `kms-policies/accelerator-s3-default-key-policy.json`, widen the policy if the account is legitimate, run LZA. The bucket's encrypted-default state is preserved across the policy fix.

### Cross-account access logging breaks after re-encrypting

When the access-log bucket itself is re-encrypted with the new CMK, source buckets in other accounts may fail to write logs because the LogDelivery service principal cannot decrypt the CMK. The key policy in this design grants `kms:Decrypt` to the LogArchive account root to keep this working. If a different account is the source of the access logs, the key policy needs to be extended to grant Decrypt to that account or to the global `delivery.logs.amazonaws.com` service principal. Discovered during implementation.

### LZA pipeline fails on the new `keyManagementService` block

If LZA v1.14.1 has a schema validation error on the block as written, fall back to creating the CMK via a custom CloudFormation stack referenced from `customizations-config.yaml`. The Config rule and remediation work the same way; only the key provisioning mechanism changes.

### Rollback after a regrettable remediation

The fastest rollback is per-rule: set `remediation.automatic: false`, run LZA. Detection continues but auto-remediation stops. Operators then manually undo the remediation that was misapplied (e.g., `aws s3api delete-bucket-policy` if S3.5 over-applied, or `aws s3api put-bucket-encryption` with the original SSE algorithm if S3.17 over-applied). The Config rule remains in place to flag the resource as non-compliant.

The faster emergency rollback is whole-rule deletion: remove the rule entry from `security-config.yaml`, run LZA. AWS Config marks the rule as deleted across the org and stops evaluation entirely.

## Testing Strategy

### Pre-merge validation

- `git diff` shows only the expected paths: `aws-accelerator-config/security-config.yaml`, `aws-accelerator-config/kms-policies/`, `aws-accelerator-config/ssm-documents/`, `aws-accelerator-config/ssm-remediation-roles/`.
- `python3 -m json.tool` validates every new JSON file.
- `yq` (or any YAML validator) validates every new YAML file.
- The LZA pipeline's built-in validation step runs as part of the pipeline itself; if the new keyManagementService block is malformed, the pipeline fails before any AWS API calls.

### LZA pipeline test

- After merge, manually trigger the LZA pipeline.
- Monitor the pipeline's `Validate` and `Build` stages — these confirm the YAML is structurally valid and renders correctly.
- Monitor the `Deploy` stage — this is where the new resources actually land in AWS.
- Pipeline run takes ~30 minutes total.

### Post-pipeline verification — KMS

In the PCI account (and one other spoke for cross-account verification):

```bash
aws kms describe-key --key-id alias/accelerator/s3-default --region us-east-2 \
  --query '{Arn:KeyMetadata.Arn, RotationEnabled:KeyMetadata.KeyRotationStatus}'

aws kms get-key-rotation-status --key-id alias/accelerator/s3-default --region us-east-2

aws ssm get-parameter --name /accelerator/kms/AcceleratorS3DefaultKey/key-arn --region us-east-2 \
  --query 'Parameter.Value' --output text
```

Expected: a CMK ARN, rotation enabled, the SSM parameter value matches the key ARN.

### Post-pipeline verification — Config rules

In the PCI account, AWS Config console:

1. Filter rules by tag `Accelerator = AWSAccelerator`.
2. Confirm all seven new rules are listed.
3. For each rule, click in and confirm a non-zero count of evaluated resources.
4. Confirm at least one resource transitions from `NON_COMPLIANT` to `COMPLIANT` within the configured retry window.

### Post-pipeline verification — Security Hub

Wait one Security Hub aggregation cycle (typically 1–2 hours), then in the Audit account (delegated admin):

```bash
aws securityhub get-findings \
  --filters '{"AwsAccountId":[{"Value":"247514667218","Comparison":"EQUALS"}], "ComplianceStatus":[{"Value":"PASSED","Comparison":"EQUALS"}]}' \
  --max-results 100 \
  --query 'Findings[?contains([`S3.5`,`S3.9`,`S3.10`,`S3.13`,`S3.17`,`SNS.1`,`CloudWatch.16`], ProductFields.ControlId)].{Control:ProductFields.ControlId, Title:Title, Status:Compliance.Status}'
```

Expected: all seven controls listed as `PASSED` for the PCI account.

### Negative test — opt-out tag

Tag a single test bucket with `accelerator:s3-lifecycle-managed = false`. After the next AWS Config evaluation cycle, confirm:
- The bucket is reported as `NON_COMPLIANT` by `s3-lifecycle-policy-check`.
- The remediation SSM execution started but completed in the `skipBucket` step (visible in the SSM execution history).
- The bucket's lifecycle configuration is unchanged.

### Cross-account verification

After PCI verification passes, repeat the AWS Config console check for `Production`, `Development`, and one Infrastructure account. Confirm the same seven rules are present and evaluating. No per-account rollout work is required — this verifies the `Root` deployment target works as intended.

### Idempotency

Re-run the LZA pipeline within 24 hours of the first run. Expected: pipeline reports no resource changes for `security-config.yaml` (the rules, documents, and CMK are already in their target state).

### Compliance evidence capture

For each verification step above, save the AWS CLI output and a screenshot of the AWS Config / Security Hub console state. Store in the same evidence location used for Wave 1.

## Implementation Tasks Preview

The implementation breakdown that the `tasks.md` will detail:

1. Add the `keyManagementService` block and the new key policy file (Components 1)
2. Add the seven Config rule entries to `awsConfig.ruleSets` (Component 2)
3. Author the three custom SSM documents (Component 3)
4. Add the three custom documents to `ssmAutomation.documentSets` (Component 5)
5. Author the six remediation IAM role policy JSON files (Component 4)
6. JSON / YAML validation locally
7. Open the PR — only `aws-accelerator-config/` paths affected
8. Merge after review
9. Trigger LZA pipeline run
10. Run all post-pipeline verification (KMS, Config, Security Hub, opt-out negative test, cross-account)
11. Capture evidence
12. Update parent strategy disposition table marking the seven controls as Wave 1/2 complete via Config-Rule-SSM
