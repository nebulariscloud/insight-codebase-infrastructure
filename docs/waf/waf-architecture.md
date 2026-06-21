# WAF architecture

## What we have

Three Web ACLs total, all REGIONAL scope, all in `us-east-2`:

| Web ACL | Owner | Attached to | Where |
|---|---|---|---|
| `ingress-alb-waf` | LZA (CFN) | `IngressALB` (Wazuh) | `aws-accelerator-config/custom-stacks/ingress-alb.yaml` |
| `scriptcase-lb-waf` | LZA (CFN) | `ScriptcaseLB` | `aws-accelerator-config/custom-stacks/scriptcase-lb.yaml` |
| `pci-alb-waf` | LZA (CFN) | `PciAlb` *(planned)* | `aws-accelerator-config/custom-stacks/pci-alb.yaml` |

The PCI Web ACL template exists but is gated on the PCI account / VPC / cert landing first. The LZA `customizations-config.yaml` block for `PciAlb` is commented out until then.

There are no CloudFront distributions and no API Gateways in scope.

## Rule set

All three Web ACLs share the same baseline:

| Priority | Rule | Action | Notes |
|---|---|---|---|
| 0 | `AWS-CommonRuleSet` | Block (with Count overrides) | OWASP-style. Ingress overrides `EC2MetaDataSSRF_BODY`, `SizeRestrictions_BODY`, `GenericRFI_BODY`, `GenericRFI_QUERYARGUMENTS` to Count for Wazuh API quirks. |
| 1 | `AWS-KnownBadInputs` | Block | |
| 2 | `AWS-IPReputation` | Block | AWS-curated bad-actor list. |
| 3 | `RateLimit` | Block | 2000 req/5min/IP on Ingress + Scriptcase, 500 req/5min/IP on PCI. |

PCI adds two more before the rate-limit rule:

| Priority | Rule | Action | Notes |
|---|---|---|---|
| 3 | `AWS-SQLi` | Block | Cardholder-data DB workloads. |
| 4 | `AWS-Linux` | Block | Linux-specific exploits. |

CloudWatch metrics + sampled requests are on for every rule.

## Logging

Owned by `terraform/live/perimeter/waf-logs/`.

- One S3 bucket per region: `aws-waf-logs-<account>-<region>` (KMS-encrypted with a dedicated CMK, versioning, lifecycle to GLACIER_IR after 30d, expiry at 365d, TLS-only bucket policy).
- `aws_wafv2_web_acl_logging_configuration` resources attach the bucket as the destination on the existing CFN-managed Web ACLs without modifying them.
- Headers `authorization` and `cookie` are redacted in WAF log records.

The Logging Configuration is a separate AWS resource from the Web ACL itself, so the LZA CFN stack does not drift when Terraform attaches a logging destination.

## Monitoring

Owned by `terraform/live/perimeter/waf-monitoring/`.

- Three SNS topics — `perimeter-waf-high`, `-medium`, `-low` — each subscribed to the corresponding `insightgroup-security-*@nebulariscloud.com` distribution list.
- Three alarms per Web ACL: `blocked-total` (Medium), `rate-limit-blocks` (High), `common-ruleset-blocks` (Medium).
- One CloudWatch dashboard `perimeter-waf` with one row per Web ACL plus a rollup row.

## Ownership boundary

- LZA owns the Web ACLs themselves (rule definitions, evaluation order, Block/Count actions).
- Terraform owns the logging destination, alarm wiring, dashboard, SNS topics, and any future IPSets / geo / Bot Control / custom rules added through the `waf-managed` module.

When SOW work expands the Web ACLs (Bot Control, geo, IP allow lists, application-specific rules), there are two paths:

1. Add to the CFN templates in `aws-accelerator-config/custom-stacks/` — slow to apply (LZA pipeline ~30 minutes), keeps everything in one place.
2. Move the Web ACLs to Terraform via `terraform import` and consume the `waf-managed` module — fast to apply (minutes), single source of truth across all WebACLs once the import is done.

The repo prefers option 2 for app-layer concerns (`terraform/README.md`, "Ownership boundary"). The Web ACLs in `custom-stacks/` are the natural next migration when day-2 tuning starts mattering more than the LZA-owned baseline.
