# Claro recordings bucket (Production)

S3 bucket for Claro recording storage in the Production spoke. Object
Lock is enabled at create time, versioning is on, and the bucket is
locked down to TLS-only with all public access blocked.

Mirrors the sibling [`amex-recordings`](../amex-recordings/) leaf - keep
changes in lockstep.

## What this owns

- One S3 bucket: `claro-recordings-prod-<account_id>` (overridable).
- Versioning, Object Lock, SSE-S3, public access block, ownership
  controls, TLS-only bucket policy, and lifecycle rules for non-current
  versions.

## What this does NOT own

- Bucket KMS key (uses SSE-S3 by default; switch to `aws:kms` and add a
  KMS resource here if your policy requires customer-managed keys).
- IAM policies for producers / consumers - the `sftp-server-claro` leaf
  owns its own instance role and a scoped policy on this bucket.
- Replication to a second region - add when retention SLAs require it.

## Object Lock notes

- Object Lock can only be **enabled at bucket creation**. If you ever
  destroy and recreate this bucket with the flag flipped off, you can't
  turn it back on without an AWS Support ticket.
- Versioning must stay enabled. Object Lock requires it.
- Default retention is **off**. Producers attach retention at PutObject
  time via `--object-lock-mode` and `--object-lock-retain-until-date`.
- To enable a default retention for every upload, set
  `enable_default_object_lock_retention = true` in `terraform.tfvars`
  and pick `default_object_lock_mode` (GOVERNANCE or COMPLIANCE) plus
  `default_object_lock_days`.
- COMPLIANCE mode is permanent until expiry - even root cannot shorten
  it. Use only when a regulator requires it.

## First-time apply

```bash
cd terraform/live/production/claro-recordings
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan
```

Apply this **before** `sftp-server-claro` so the instance role's scoped
S3 policy resolves to a bucket that already exists. Terraform won't fail
the policy attachment if the bucket is missing (the policy just
references an ARN), but uploads from the instance will 404 until this
leaf is applied.

## Verifying

```bash
BUCKET=$(terraform output -raw bucket_name)

aws s3api get-bucket-versioning --bucket "$BUCKET"
# Expect: { "Status": "Enabled" }

aws s3api get-object-lock-configuration --bucket "$BUCKET"
# Expect: ObjectLockConfiguration.ObjectLockEnabled = "Enabled"

aws s3api get-public-access-block --bucket "$BUCKET"
# Expect: all four flags = true

aws s3api get-bucket-encryption --bucket "$BUCKET"
# Expect: SSEAlgorithm = AES256
```

## Common gotchas

- `BucketAlreadyExists`: pick a different `bucket_name` in tfvars. S3
  bucket names are globally unique across all AWS accounts.
- `Object Lock configuration not found`: the bucket exists but Object
  Lock wasn't set. This only happens if the bucket was created outside
  this stack. Recreate the bucket via Terraform.
- Cannot delete an object: Object Lock is doing its job. With
  GOVERNANCE mode, an admin can pass `--bypass-governance-retention`
  on `delete-object`. With COMPLIANCE mode, wait for the retention
  period to expire.
