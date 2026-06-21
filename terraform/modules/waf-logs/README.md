# Module: waf-logs

S3 bucket + KMS CMK + (optional) `aws_wafv2_web_acl_logging_configuration` attachments for AWS WAF logs.

Designed to enable WAF logging on Web ACLs that this Terraform tree doesn't otherwise own — specifically the LZA-managed `ingress-alb-waf` and `scriptcase-lb-waf` Web ACLs. The `aws_wafv2_web_acl_logging_configuration` resource is independent of the Web ACL itself, so attaching here does not mutate the underlying CFN stack.

## What it builds

- KMS CMK with key rotation, aliased `alias/waf-logs-<name>`. Allows the AWS Logs Delivery service to encrypt scoped to the current account.
- S3 bucket named exactly as `var.bucket_name` (must start with `aws-waf-logs-` — the WAF API enforces this prefix).
  - Versioning on
  - SSE-KMS with the CMK above, bucket key enabled
  - Public access blocked (all four flags)
  - Lifecycle: `transition_to_glacier_ir_days` → GLACIER_IR, `log_retention_days` → expire
  - TLS-only bucket policy (defense in depth)
  - `delivery.logs.amazonaws.com` write permissions scoped to this account
- One `aws_wafv2_web_acl_logging_configuration` per Web ACL ARN passed in `attach_to_web_acl_arns`, with header redaction for `authorization` and `cookie` by default.

## Why direct-to-S3 instead of Firehose

- Firehose writes are subject to `lza-core-guardrails-1` (SCP restricts Firehose Create/Delete/Update to `AWSAccelerator`-prefixed streams). Direct-to-S3 sidesteps this entirely.
- WAF supports S3 as a first-class logging destination since 2021. WAF writes ~5-minute partitions as `.gz` objects under `AWSLogs/<account>/WAFLogs/<region>/<webacl>/...`.
- Storage cost dominates over delivery cost at WAF volumes; S3 + Athena is cheaper than CloudWatch Logs ingestion at any meaningful scale.

## Usage — perimeter logging stack

```hcl
module "waf_logs" {
  source = "../../../modules/waf-logs"

  name        = "perimeter-us-east-2"
  bucket_name = "aws-waf-logs-${var.account_id}-${var.region}"

  # Attach to the existing CFN-managed Web ACLs.
  # ARNs are looked up by name via data sources in the leaf.
  attach_to_web_acl_arns = [
    data.aws_wafv2_web_acl.ingress.arn,
    data.aws_wafv2_web_acl.scriptcase.arn,
  ]
}
```

## Athena

Once logs land, point Athena at them with the standard WAF schema. The bucket layout matches AWS docs, so the partition projection table from `https://docs.aws.amazon.com/waf/latest/developerguide/logging-querying.html` works without modification.
