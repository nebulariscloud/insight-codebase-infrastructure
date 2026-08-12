# live/perimeter/waf-logs

Builds the central WAF log destination for the Perimeter account / us-east-2 and turns on logging for **every** REGIONAL Web ACL listed in `var.web_acl_names`.

As of 2026-08-10 that is all four:

| Web ACL | Fronts | Owned by |
|---|---|---|
| `ingress-alb-waf` | `ingress-alb` (Wazuh) | CFN / LZA custom-stack |
| `scriptcase-lb-waf` | `scriptcase-lb` | CFN / LZA custom-stack |
| `crm-alb-waf` | `crm-alb` | Terraform (`live/perimeter/crm-alb`) |
| `osticket-alb-waf` | `osticket-alb` | Terraform (`live/perimeter/osticket-alb`) |

## What this leaf does

- Creates `aws-waf-logs-<account>-<region>` S3 bucket with KMS CMK, versioning, lifecycle to GLACIER_IR after 30d, expiry at `log_retention_days`, and TLS-only bucket policy.
- Creates one `aws_wafv2_web_acl_logging_configuration` per name in `var.web_acl_names`. Headers `authorization` and `cookie` are redacted in the log records.

## Adding a Web ACL

One line in `terraform.tfvars`:

```hcl
web_acl_names = [
  "ingress-alb-waf",
  "scriptcase-lb-waf",
  "crm-alb-waf",
  "osticket-alb-waf",
  "my-new-waf", # <- add here, in the same PR that creates the Web ACL
]
```

The module's `for_each` is keyed by **ARN**, so appending a name is a create-only plan. Existing logging configurations keep their state addresses and are never replaced.

**Do this in the same PR that creates the Web ACL.** Until 2026-08-10 this leaf took one variable per Web ACL (`ingress_web_acl_name`, `scriptcase_web_acl_name`) with no way to express a third. `crm-alb-waf` and `osticket-alb-waf` were created in July, got no logging, and nothing failed — the leaf planned clean the whole time. The list shape plus `waf-finish-checklist.md` step 6 is the fix.

## What this leaf does NOT do

- It does not modify the Web ACLs themselves. The CFN-owned ones stay CFN-owned by the LZA pipeline; `aws_wafv2_web_acl_logging_configuration` is a separate AWS resource from the Web ACL, so the CFN stack will not drift.
- It does not create Athena tables. Once logs are flowing, build them in a separate analytics leaf.

## Apply order

This leaf can apply standalone — it has no dependencies on the `waf-monitoring` leaf.

After apply, verify logging is attached **and objects are actually landing** for every Web ACL. Attachment alone is not proof; that distinction is what step 6 of the finish checklist exists to catch:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  arn=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
    --query "WebACLs[?Name=='$acl'].ARN | [0]" --output text)
  dest=$(aws wafv2 get-logging-configuration --resource-arn "$arn" --region us-east-2 \
    --query 'LoggingConfiguration.LogDestinationConfigs[0]' --output text 2>/dev/null || echo NONE)
  n=$(aws s3 ls "s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/$acl/" \
    --recursive 2>/dev/null | wc -l | tr -d ' ')
  printf "%-20s dest=%-50s objects=%s\n" "$acl" "$dest" "$n"
done
```

The first WAF log objects appear within ~5 minutes of an associated ALB receiving traffic.

## Cost

- S3 storage: a few cents to a few dollars per month depending on traffic volume and lifecycle.
- KMS: ~$1/month for the CMK plus per-request charges (negligible).
- `s3:PutObject` requests: WAF batches into ~5-minute objects per partition, so request volume is low.
