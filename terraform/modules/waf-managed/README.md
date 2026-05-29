# Module: waf-managed

WAFv2 Web ACL with the AWS managed rule sets and rate limiting. Same shape as the WAF block inside the existing `ingress-alb.yaml`, made reusable.

Includes:

- `AWSManagedRulesCommonRuleSet` (OWASP-style coverage) with configurable Count overrides for known false-positive rules.
- `AWSManagedRulesKnownBadInputsRuleSet` (toggleable).
- `AWSManagedRulesAmazonIpReputationList` (toggleable).
- `AWSManagedRulesAnonymousIpList` (off by default; turn on if Tor/VPN traffic is not legitimate for your app).
- A rate-based rule, default 2000 req / 5min / IP.

CloudWatch metrics + sampled requests are on for every rule.

## Usage

```hcl
module "waf" {
  source = "../../../modules/waf-managed"

  name       = "my-app-waf"
  scope      = "REGIONAL"   # for ALB
  rate_limit = 5000

  # Optional: ship logs somewhere
  logging_destination_arns = [aws_cloudwatch_log_group.waf.arn]
}

module "alb" {
  source          = "../../../modules/alb"
  waf_web_acl_arn = module.waf.web_acl_arn
  # ...
}
```

## CloudFront

If you need a Web ACL for CloudFront, set `scope = "CLOUDFRONT"` and run Terraform with the AWS provider pinned to `us-east-1` (CloudFront WAF is global but only manageable from us-east-1). Easiest pattern: a separate provider alias in the leaf.
