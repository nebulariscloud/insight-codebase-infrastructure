# live/perimeter/waf-logs

Builds the central WAF log destination for the Perimeter account / us-east-2 and turns on logging for the two existing CFN-managed Web ACLs (`ingress-alb-waf`, `scriptcase-lb-waf`).

## What this leaf does

- Creates `aws-waf-logs-<account>-<region>` S3 bucket with KMS CMK, versioning, lifecycle to GLACIER_IR after 30d, expiry at `log_retention_days`, and TLS-only bucket policy.
- Creates one `aws_wafv2_web_acl_logging_configuration` per Web ACL listed in `var.*_web_acl_name`. Headers `authorization` and `cookie` are redacted in the log records.

## What this leaf does NOT do

- It does not modify the Web ACLs themselves. Those stay CFN-owned by the LZA pipeline. `aws_wafv2_web_acl_logging_configuration` is a separate AWS resource from the Web ACL — the CFN stack will not drift.
- It does not create Athena tables. Once logs are flowing, build them in a separate analytics leaf.

## Apply order

This leaf can apply standalone — it has no dependencies on the `waf-monitoring` leaf.

After apply, verify:

```bash
aws wafv2 get-logging-configuration --resource-arn <arn-from-output>
aws s3 ls s3://aws-waf-logs-<account>-<region>/AWSLogs/ --recursive | head
```

The first WAF log objects appear within ~5 minutes of an associated ALB receiving traffic.

## Cost

- S3 storage: a few cents to a few dollars per month depending on traffic volume and lifecycle.
- KMS: ~$1/month for the CMK plus per-request charges (negligible).
- `s3:PutObject` requests: WAF batches into ~5-minute objects per partition, so request volume is low.
