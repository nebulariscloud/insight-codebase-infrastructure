# Snapshot & AMI Migration Guide

## Overview

This document covers:
1. Sharing EBS snapshots and AMIs from a source account to target account **395516496764**
2. Copying shared resources in the target account so you own them
3. Moving resources from **us-east-1** to **us-east-2**
4. Handling **encrypted** snapshots/AMIs and re-encrypting with a new KMS key

> **Tip:** All commands below are written on a single line to avoid shell line-continuation (`\`) issues. Copy and paste as-is.

---

## Prerequisites

- AWS CLI configured with appropriate credentials for both source and target accounts
- IAM permissions: `ec2:ModifySnapshotAttribute`, `ec2:ModifyImageAttribute`, `ec2:CopySnapshot`, `ec2:CopyImage`
- For encrypted resources: `kms:CreateGrant`, `kms:Decrypt`, `kms:Encrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey`

---

## Part 1: Unencrypted Snapshots & AMIs

### Step 1: Share from Source Account

**Share an EBS Snapshot:**
```bash
aws ec2 modify-snapshot-attribute --snapshot-id snap-XXXXXXXXXXXXXXXXX --attribute createVolumePermission --operation-type add --user-ids 395516496764
```

**Share an AMI:**
```bash
aws ec2 modify-image-attribute --image-id ami-XXXXXXXXXXXXXXXXX --launch-permission "Add=[{UserId=395516496764}]"
```

### Step 2: Copy in Target Account (395516496764) — Same Region

**Copy snapshot:**
```bash
aws ec2 copy-snapshot --source-region us-east-1 --source-snapshot-id snap-XXXXXXXXXXXXXXXXX --description "Copied from source account"
```

**Copy AMI:**
```bash
aws ec2 copy-image --source-region us-east-1 --source-image-id ami-XXXXXXXXXXXXXXXXX --name "my-copied-ami"
```

### Step 3: Move from us-east-1 to us-east-2

**Copy snapshot cross-region:**
```bash
aws ec2 copy-snapshot --region us-east-2 --source-region us-east-1 --source-snapshot-id snap-XXXXXXXXXXXXXXXXX --description "Copied to us-east-2"
```

**Copy AMI cross-region:**
```bash
aws ec2 copy-image --region us-east-2 --source-region us-east-1 --source-image-id ami-XXXXXXXXXXXXXXXXX --name "my-ami-us-east-2"
```

---

## Part 2: Encrypted Snapshots & AMIs

When the snapshot/AMI is encrypted with a **customer-managed KMS key (CMK)**, you must grant the target account access to that key. **AWS-managed keys (`aws/ebs`) cannot be shared** — if the source used `aws/ebs`, see the workaround below.

### Step 1: Update KMS Key Policy in Source Account

In the **source account**, edit the KMS key policy to allow the target account to use the key. Add this statement to the key policy:

```json
{
  "Sid": "AllowTargetAccountUse",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::395516496764:root"
  },
  "Action": [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
    "kms:DescribeKey",
    "kms:CreateGrant"
  ],
  "Resource": "*"
}
```

Apply via CLI (replace `KEY_ID` and load the full policy from a file):
```bash
aws kms put-key-policy --key-id KEY_ID --policy-name default --policy file://key-policy.json
```

### Step 2: Share the Snapshot or AMI

Same commands as the unencrypted case:
```bash
aws ec2 modify-snapshot-attribute --snapshot-id snap-XXXXXXXXXXXXXXXXX --attribute createVolumePermission --operation-type add --user-ids 395516496764
```

```bash
aws ec2 modify-image-attribute --image-id ami-XXXXXXXXXXXXXXXXX --launch-permission "Add=[{UserId=395516496764}]"
```

### Step 3: Copy & Re-Encrypt in Target Account with Your Own KMS Key

In the **target account**, create or use your own CMK, then copy + re-encrypt in one step. This frees you from the source account's KMS key.

**Get your target-account KMS key ARN:**
```bash
aws kms describe-key --key-id alias/my-target-key --region us-east-2 --query "KeyMetadata.Arn" --output text
```

**Copy snapshot cross-region AND re-encrypt with target-account key:**
```bash
aws ec2 copy-snapshot --region us-east-2 --source-region us-east-1 --source-snapshot-id snap-XXXXXXXXXXXXXXXXX --encrypted --kms-key-id arn:aws:kms:us-east-2:395516496764:key/YOUR-TARGET-KEY-ID --description "Re-encrypted copy in us-east-2"
```

**Copy AMI cross-region AND re-encrypt:**
```bash
aws ec2 copy-image --region us-east-2 --source-region us-east-1 --source-image-id ami-XXXXXXXXXXXXXXXXX --encrypted --kms-key-id arn:aws:kms:us-east-2:395516496764:key/YOUR-TARGET-KEY-ID --name "my-reencrypted-ami"
```

After this completes, the new snapshot/AMI is fully under the target account's control with the target-account KMS key. You no longer depend on the source account's key.

---

## Part 3: Workaround if Source Used `aws/ebs` (AWS-Managed Key)

AWS-managed keys can't be shared with other accounts. The workaround:

1. **In the source account**, copy the snapshot to itself, re-encrypting with a **customer-managed CMK**:
   ```bash
   aws ec2 copy-snapshot --source-region us-east-1 --source-snapshot-id snap-XXXXXXXXXXXXXXXXX --encrypted --kms-key-id arn:aws:kms:us-east-1:SOURCE_ACCT:key/SOURCE-CMK-ID --description "Re-encrypted with CMK for sharing"
   ```
2. Update the CMK's key policy to allow the target account (Part 2, Step 1).
3. Share the **new** snapshot ID with the target account.
4. Target account copies + re-encrypts with its own key (Part 2, Step 3).

---

## Verification Commands

**List shared snapshots visible in target account:**
```bash
aws ec2 describe-snapshots --region us-east-1 --restorable-by-user-ids self
```

**List AMIs shared with you:**
```bash
aws ec2 describe-images --region us-east-1 --executable-users self
```

**Check snapshot copy progress:**
```bash
aws ec2 describe-snapshots --region us-east-2 --snapshot-ids snap-XXXXXXXXXXXXXXXXX --query "Snapshots[*].{ID:SnapshotId,Progress:Progress,State:State,Encrypted:Encrypted,KmsKeyId:KmsKeyId}"
```

**Check AMI copy state:**
```bash
aws ec2 describe-images --region us-east-2 --image-ids ami-XXXXXXXXXXXXXXXXX --query "Images[*].{ID:ImageId,State:State}"
```

**Verify which KMS key encrypts a snapshot:**
```bash
aws ec2 describe-snapshots --snapshot-ids snap-XXXXXXXXXXXXXXXXX --query "Snapshots[0].KmsKeyId"
```

---

## End-to-End Workflow

```
Source Account (us-east-1)
    │
    ├── 1. (Encrypted only) Update KMS key policy to allow 395516496764
    ├── 2. Share snapshot/AMI with 395516496764
    │
    ▼
Target Account 395516496764 (us-east-1)
    │
    ├── 3. Copy snapshot/AMI (re-encrypt with target-account CMK if encrypted)
    │
    ▼
Target Account 395516496764 (us-east-2)
    │
    └── 4. Copy cross-region (--encrypted --kms-key-id <target-key-arn>)
```

---

## Notes & Gotchas

- **Always copy** shared resources rather than using them directly. Shared access can be revoked, breaking dependencies.
- **`aws/ebs` cannot be shared.** If the source used the default AWS-managed key, re-encrypt to a CMK first.
- **Cross-region + re-encrypt in one step** is supported. You don't need to copy in the same region first.
- **Line continuations:** If you must split commands across lines, ensure no trailing spaces after `\` and that `\` is the very last character.
- **AMIs with multiple snapshots:** Copying an AMI automatically copies all associated snapshots. You only need to issue `copy-image` once.
- After the copy is `completed`/`available`, you can deregister/delete the older copies if no longer needed.
