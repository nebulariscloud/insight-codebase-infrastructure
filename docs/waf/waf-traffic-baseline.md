# WAF traffic baseline

Capture and update this doc weekly during the first month, then monthly. The point is to have a defensible "normal" so that alarm thresholds aren't pulled out of thin air.

## How to capture

1. Open the `perimeter-waf` CloudWatch dashboard.
2. Set the time range to "Last 7 days".
3. Hover the line graphs to read p50 / max values per Web ACL per metric. Note the worst-case 5-minute window in each case.

## Current baseline

> **Status:** Pending first week of dashboard data. Update this section once the `waf-monitoring` leaf has been live for at least 7 days.

### `ingress-alb-waf` (Wazuh)

| Metric | p50 / 5min | p95 / 5min | Max / 5min | Notes |
|---|---|---|---|---|
| `AllowedRequests` | TBD | TBD | TBD | |
| `BlockedRequests` (ALL) | TBD | TBD | TBD | Mostly internet scanner noise hitting the IP reputation list. |
| `BlockedRequests` (RateLimit) | TBD | TBD | TBD | Should be near zero unless under attack. |
| `BlockedRequests` (CommonRuleSet) | TBD | TBD | TBD | |
| `CountedRequests` | TBD | TBD | TBD | Sub-rules in Count: see waf-tuning-guide.md. |

### `scriptcase-lb-waf`

| Metric | p50 / 5min | p95 / 5min | Max / 5min | Notes |
|---|---|---|---|---|
| `AllowedRequests` | TBD | TBD | TBD | |
| `BlockedRequests` (ALL) | TBD | TBD | TBD | |
| `BlockedRequests` (RateLimit) | TBD | TBD | TBD | |
| `BlockedRequests` (CommonRuleSet) | TBD | TBD | TBD | |
| `CountedRequests` | TBD | TBD | TBD | Currently no Count overrides on this Web ACL. |

### `pci-alb-waf`

> Not yet deployed (gated on PCI account / VPC / cert landing). Baseline starts after first deploy.

## Threshold derivation

Thresholds in `terraform/live/perimeter/waf-monitoring/main.tf` are currently:

| Threshold variable | Default | Rationale |
|---|---|---|
| `blocked_requests_threshold` | 1000 / 5min | Generous; catches obvious anomalies, not background noise. Tighten to ~3× p95 once baseline is captured. |
| `rate_limit_block_threshold` | 200 / 5min | Should be near zero in steady state. A spike means a sustained source is hitting the cap — actionable signal. |
| `common_rule_set_block_threshold` | 500 / 5min | Sized for typical scanner background. Tighten to ~3× p95 once baseline is captured. |

When you tighten these, edit the leaf, open a PR, merge. CI will apply.

## Known traffic patterns

Notable contributors to the `Allowed` and `Counted` numbers — these are not problems, they're things that look like problems if you don't know they exist:

- **Wazuh internal API** — sends `127.0.0.1` in body for health checks, large bodies for index pattern lookups. Triggers `EC2MetaDataSSRF_BODY` and `SizeRestrictions_BODY` (both currently set to Count on `ingress-alb-waf`).
- **Global Accelerator health checks** — every 30s probe to `:80` on the ALB returns a 301 redirect. Counts as `AllowedRequests`.
- **Internet scanner background** — constant low-level traffic from internet-wide scanners. Most caught by `AWS-IPReputation` or `AWS-CommonRuleSet`. Floor of `BlockedRequests` is non-zero by design.

## Update procedure

1. Open this file.
2. Replace the TBD cells with actual numbers from the dashboard.
3. Set the date in the changelog below.
4. Commit. No PR review required for documentation-only changes.

## Changelog

- *Pending first capture* — leaves applied, dashboards live, baseline collection in progress.
