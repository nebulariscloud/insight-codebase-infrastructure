# F9 recordings bucket (Production)

S3 bucket for F9 recording storage in the Production spoke. Object Lock
is enabled at create time, versioning is on, and the bucket is locked
down to TLS-only with all public access blocked.

Mirrors the sibling [`amex-recordings`](../amex-recordings/) and
[`claro-recordings`](../claro-recordings/) leaves - keep changes in
lockstep.

## What this owns

- One S3 bucket: `f9-recordings-prod-<account_id>` (overridable).
- Versioning, Object Lock, SSE-S3, public access block, ownership
  controls, TLS-only bucket policy, and lifecycle rules for non-current
  versions.

## What this does NOT own

- Bucket KMS key (uses SSE-S3 by default; the S3.17 Security Hub
  auto-remediation flips live buckets to SSE-KMS with the org-wide
  customer-managed key after the fact - see the note in
  `sftp-server-f9/terraform.tfvars`).
- IAM policies for producers / consumers - the `sftp-server-f9` leaf
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

## Apply order

CI applies leaves serially on merge to `main`. This leaf should land
**before** `sftp-server-f9` so the instance role's scoped S3 policy
resolves to a bucket that already exists. Terraform won't fail the
policy attachment if the bucket is missing (the policy just references an
ARN string), but uploads from the instance will 404 until this leaf is
applied.

## Verifying after apply

```bash
BUCKET=f9-recordings-prod-395516496764

aws s3api get-bucket-versioning --bucket "$BUCKET" --region us-east-2
# Expect: { "Status": "Enabled" }

aws s3api get-object-lock-configuration --bucket "$BUCKET" --region us-east-2
# Expect: ObjectLockConfiguration.ObjectLockEnabled = "Enabled"

aws s3api get-public-access-block --bucket "$BUCKET" --region us-east-2
# Expect: all four flags = true

aws s3api get-bucket-encryption --bucket "$BUCKET" --region us-east-2
# Expect: SSEAlgorithm = AES256 at first. If Security Hub S3.17
# auto-remediation has run, expect aws:kms with the org-wide key
# adacb68f-a099-486c-bfce-56bb696ed126 instead - that is expected drift,
# and the sftp-server-f9 leaf already grants the instance role KMS access
# to that key.
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
