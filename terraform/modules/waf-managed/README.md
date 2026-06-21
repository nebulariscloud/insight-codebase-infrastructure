# Module: waf-managed

WAFv2 Web ACL with the AWS managed rule sets, rate limiting, and (opt-in) Bot Control / geo gating / IP allow + deny lists / custom rules.

Same shape as the WAF block inside `custom-stacks/ingress-alb.yaml`, made reusable. Bot Control and geo are off by default so cost is explicit at the leaf.

## Rule evaluation order

| Priority | Rule | Notes |
|---|---|---|
| 0 | `AllowList` | Vetted IPs short-circuit to Allow. Created when `allow_ip_cidrs` / `ip_set_ipv6_allow_cidrs` is non-empty. |
| 1 | `DenyList` | Known-bad IPs short-circuit to Block. |
| 2 | `GeoAllow` / `GeoBlock` | One or the other - they're mutually exclusive. |
| 3 | `AWS-CommonRuleSet` | OWASP-style coverage with configurable Count overrides for known false-positive sub-rules. |
| 4 | `AWS-KnownBadInputs` | Toggleable, default on. |
| 5 | `AWS-IPReputation` | Toggleable, default on. |
| 6 | `AWS-AnonymousIP` | Off by default; turn on if Tor/VPN traffic is not legitimate for your app. |
| 7 | `AWS-BotControl` | Off by default. ~$10/Web ACL/month + per-request charges. |
| 10 | `RateLimit` | Default 2000 req/5min/IP, blocking. |
| 100+ | `custom_rules` | Caller-defined patterns. |

CloudWatch metrics + sampled requests are on for every rule.

## Usage

Minimal — same as before:

```hcl
module "waf" {
  source = "../../../modules/waf-managed"

  name       = "my-app-waf"
  scope      = "REGIONAL"   # for ALB
  rate_limit = 5000
}
```

Full example with the new toggles:

```hcl
module "waf" {
  source = "../../../modules/waf-managed"

  name = "ingress-alb-waf"

  # Vetted partner egress IPs - skip every other rule
  allow_ip_cidrs = ["198.51.100.0/24"]

  # Allow PR + US only; everywhere else blocked
  geo_allow_country_codes = ["PR", "US"]

  # Bot Control in Count for the first two weeks of tuning, then promote
  enable_bot_control             = true
  bot_control_inspection_level   = "COMMON"
  bot_control_overrides_to_count = ["SignalAutomatedBrowser", "CategoryHttpLibrary"]

  # Application-specific rule: tighter rate-limit on /login
  custom_rules = [
    {
      name     = "LoginRateLimit"
      priority = 100
      action   = "block"
      rate_based_statement = {
        limit                      = 100
        aggregate_key_type         = "IP"
        scope_down_uri_starts_with = "/login"
      }
    },
  ]

  # Send WAF logs to S3 (bucket name must start with aws-waf-logs-)
  logging_destination_arns = [
    "arn:aws:s3:::aws-waf-logs-perimeter-us-east-2",
  ]
}
```

## CloudFront

Set `scope = "CLOUDFRONT"` and run Terraform with the AWS provider pinned to `us-east-1` (the CloudFront WAF control plane only lives there). Easiest pattern: a `provider "aws" { alias = "us_east_1" }` in the leaf and pass the alias.

## Logging

`aws_wafv2_web_acl_logging_configuration` is a separate resource and **does not modify the Web ACL itself**. That means this module (or a sibling leaf) can attach logging to a Web ACL Terraform doesn't otherwise own — useful for the CFN-managed `ingress-alb-waf` and `scriptcase-lb-waf` Web ACLs that LZA created. See `terraform/live/perimeter/waf-logs/` for that pattern.

WAF requires the destination name to start with `aws-waf-logs-` (S3 bucket, CloudWatch log group, or Firehose stream). The module won't validate this; the WAF API will reject the configuration if you pass a non-prefixed ARN.

## Custom rules — supported shapes

The `custom_rules` variable covers two common patterns. Anything more complex should live directly in the leaf as a separate `aws_wafv2_web_acl_rule` (the WebACL accepts external rule references via the `rule_action_override` mechanism, but most teams just inline them in the WebACL).

**Byte-match** (block / allow / count / captcha / challenge a URI / query / header / method match):

```hcl
{
  name     = "BlockBadUserAgent"
  priority = 110
  action   = "block"
  byte_match_statement = {
    search_string         = "sqlmap"
    field                 = "single_header_user_agent"
    positional_constraint = "CONTAINS"
    text_transformations  = ["LOWERCASE"]
  }
}
```

`field` accepts: `uri_path`, `query_string`, `method`, `single_header_user_agent`, `single_header_referer`.

**Rate-based, optionally scoped to a URI prefix**:

```hcl
{
  name     = "ApiRateLimit"
  priority = 120
  action   = "block"
  rate_based_statement = {
    limit                      = 500
    aggregate_key_type         = "IP"
    scope_down_uri_starts_with = "/api/"
  }
}
```
