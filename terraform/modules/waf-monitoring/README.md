# Module: waf-monitoring

CloudWatch alarms + dashboard + SNS routing for WAF Web ACLs.

## What it builds

- Three SNS topics (`<name>-high`, `<name>-medium`, `<name>-low`), each with an email subscription. Email addresses are sourced from `replacements-config.yaml` (`SecurityHigh / Medium / Low`).
- Three CloudWatch alarms per Web ACL:
  - `blocked-total` — total `BlockedRequests` (rule `ALL`). Medium-severity. Catches the "things are getting blocked at unusual volume" case.
  - `rate-limit-blocks` — `BlockedRequests` for rule `RateLimit`. High-severity. Sustained spike here is a DDoS / abuse signal.
  - `common-ruleset-blocks` — `BlockedRequests` for rule `AWS-CommonRuleSet`. Medium. Spike here usually means a new attack pattern or a bad deploy that's producing payloads that look hostile.
- One CloudWatch dashboard:
  - One row of three widgets per Web ACL: traffic (allowed / blocked / counted), blocks broken down by rule, and a single-value rate-limit panel.
  - Rollup row across all Web ACLs.

## Usage

```hcl
module "waf_mon" {
  source = "../../../modules/waf-monitoring"

  name = "perimeter-waf"

  web_acls = {
    ingress = {
      name   = "ingress-alb-waf"
      scope  = "REGIONAL"
      region = "us-east-2"
    }
    scriptcase = {
      name   = "scriptcase-lb-waf"
      scope  = "REGIONAL"
      region = "us-east-2"
    }
  }

  # From aws-accelerator-config/replacements-config.yaml
  sns_email_high   = "insightgroup-security-high@nebulariscloud.com"
  sns_email_medium = "insightgroup-security-medium@nebulariscloud.com"
  sns_email_low    = "insightgroup-security-low@nebulariscloud.com"
}
```

## Tuning thresholds

Defaults are intentionally generous so the alarms don't chirp on background internet noise. Once the dashboard has a week of data, narrow the thresholds:

- `blocked_requests_threshold` — set to ~3× the p95 over 5-min windows.
- `rate_limit_block_threshold` — set just above the highest legitimate burst you've observed.
- `common_rule_set_block_threshold` — set above peak normal block rate from scanners.

## SNS subscription confirmation

Email subscriptions stay in `pending` until the recipient clicks the confirmation link in the inbox. Until then alarms fire but no email lands. AWS sends one confirmation per address per topic.
