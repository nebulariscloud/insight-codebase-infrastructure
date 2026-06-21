# live/perimeter/waf-monitoring

Alarms + dashboard + SNS routing for the Perimeter Web ACLs.

## What this leaf does

- Three SNS topics by severity (`perimeter-waf-high`, `-medium`, `-low`), each subscribed to the matching `insightgroup-security-*@nebulariscloud.com` distribution list from `aws-accelerator-config/replacements-config.yaml`.
- Three alarms per Web ACL:
  - `blocked-total` (Medium)
  - `rate-limit-blocks` (High)
  - `common-ruleset-blocks` (Medium)
- One CloudWatch dashboard `perimeter-waf` with one row per Web ACL plus a rollup row.

## Apply order

Independent of `waf-logs` — can apply in either order. Both leaves only consume the Web ACL names; they don't create or modify them.

## After apply

1. Confirm the SNS subscriptions: AWS sends one confirmation email per address. Click the link or alarms will fire silently.
2. Visit CloudWatch → Dashboards → `perimeter-waf`. With no traffic-driven blocks, the line graphs are flat — that's the baseline.
3. Wait one week. Open `terraform.tfvars` (the `*_threshold` overrides) and tighten thresholds based on real p95s.

## Tuning

The defaults are sized for an account that sees ambient internet scanner noise but no current attack pressure. If you have one of these and don't want to tune:

- `blocked_requests_threshold = 1000` (per 5min, sustained 10min)
- `rate_limit_block_threshold = 200` (per 5min, sustained 10min)
- `common_rule_set_block_threshold = 500` (per 5min, sustained 10min)

Drop these to `~3× the p95 over 5-min windows` once you have a week of real data. Open the dashboard, scroll the time range to the past week, hover the lines, pick the value.
