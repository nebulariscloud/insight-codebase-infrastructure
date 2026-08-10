# WAF traffic baseline

Defensible "normal" for the Perimeter Web ACLs, so alarm thresholds are derived rather than guessed.

| | |
|---|---|
| **Account** | Perimeter `713939170920` |
| **Region** | us-east-2 |
| **Captured** | 2026-08-08 |
| **Window** | 4 days |
| **Granularity** | `Sum` per 5-minute period — matches the alarm period |

> **Run baseline queries in Perimeter, not Production.** Every WAF resource lives in `713939170920`. Querying from Production returns zero metrics and looks identical to a broken pipeline — this cost several hours of misdiagnosis on 2026-08-08. Assert the account first:
>
> ```bash
> ACCT=$(aws sts get-caller-identity --query Account --output text)
> [ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT)"; exit 1; }
> ```

## How to capture

CloudWatch caps `get-metric-statistics` at 1440 datapoints, so 5-minute granularity limits you to ~4 days per call (7 days at `--period 300` is 2016 points and errors out).

```bash
for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  for metric in AllowedRequests BlockedRequests CountedRequests; do
    echo "=== $acl / $metric ==="
    aws cloudwatch get-metric-statistics \
      --namespace AWS/WAFV2 --metric-name $metric \
      --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=ALL \
      --start-time "$(date -u -d '4 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --period 300 --statistics Sum --region us-east-2 \
      --query 'sort_by(Datapoints,&Sum)[-5:].[Timestamp,Sum]' --output table
  done
done
```

Swap `Rule=ALL` for `Rule=AWS-CommonRuleSet` / `AWS-KnownBadInputs` / `AWS-IPReputation` / `RateLimit` for the per-rule split.

Note the namespace is **`AWS/WAFV2`** — capital V, and CloudWatch namespaces are case-sensitive.

## Current baseline

### `ingress-alb-waf` — Wazuh dashboard / API

| Metric | Top-5 five-minute Sums | Notes |
|---|---|---|
| `AllowedRequests` | 763, 526, 483, 462, 461 | Includes Global Accelerator health checks every 30s |
| `BlockedRequests` (ALL) | **2464, 2225, 1958, 1081, 1055** | Blocks exceed allows at peak |
| `BlockedRequests` (AWS-IPReputation) | **1712, 1510, 1312** | ~65% of all blocks |
| `BlockedRequests` (AWS-CommonRuleSet) | 419, 302, 292 | |
| `BlockedRequests` (AWS-KnownBadInputs) | 387, 354, 319 | |
| `BlockedRequests` (RateLimit) | none | Never fired in 4 days |
| `CountedRequests` | 10, 5, 2, 2, 2 | The 4 Count-overridden sub-rules; negligible |

### `scriptcase-lb-waf`

| Metric | Top-5 five-minute Sums | Notes |
|---|---|---|
| `AllowedRequests` | 972, 961, 961, 958, 957 | Higher allowed volume than ingress |
| `BlockedRequests` (ALL) | 297, 262, 232, 227, 220 | ~8x lower than ingress |
| `BlockedRequests` (AWS-CommonRuleSet) | **231, 205, 151** | **Dominant blocker here** |
| `BlockedRequests` (AWS-IPReputation) | 182, 144, 31 | |
| `BlockedRequests` (AWS-KnownBadInputs) | 107, 101, 92 | |
| `BlockedRequests` (RateLimit) | none | Never fired in 4 days |
| `CountedRequests` | none | No Count overrides on this Web ACL — matches `scriptcase-lb.yaml` |

### `crm-alb-waf` and `osticket-alb-waf`

Created by PR #60. **No baseline yet** — capture after a week of traffic and set per-ACL thresholds. They currently inherit the module defaults.

### `pci-alb-waf`

Not deployed. PCI account and VPC exist but hold no workload, no ACM certificate, and no ALB. Baseline starts after first deploy.

## What the numbers mean

**Blocks exceeding allows on ingress is not an incident.** IP reputation is ~65% of the blocks. `AWSManagedRulesAmazonIpReputationList` blocks AWS-curated known-bad source IPs, so traffic dominated by that rule is botnet and mass-scanner background being cleanly dropped. That is WAF working, not evidence of a targeted attack.

**The two Web ACLs have genuinely different threat profiles.** On ingress, IPReputation (1712) dwarfs CommonRuleSet (419). On scriptcase the ordering inverts — CommonRuleSet (231) outranks IPReputation (182). Scriptcase is a PHP application and attracts proportionally more application-layer probing. This is why thresholds are per-Web-ACL rather than global.

**The rate limit is well calibrated.** Zero datapoints on the `RateLimit` rule across 4 days on both Web ACLs. Nothing is reaching 2000 req/5min/IP, and the rule is not false-positiving. No reason to change the limit itself.

**Two threshold breaches went unreported.** Consecutive 5-minute windows on 2026-08-06 19:23→19:28 (1958, 1055) and 2026-08-07 00:23→00:28 (2225, 1081) both exceeded the then-configured 1000 threshold with `evaluation_periods = 2`. Neither alarmed, because the CloudWatch namespace defect was not fixed until 2026-08-08. The threshold value was sound; the plumbing was not. Both were IP-reputation-dominated scanner sweeps.

## Threshold derivation

Configured in `terraform/live/perimeter/waf-monitoring/terraform.tfvars`.

| Web ACL | Alarm | Peak observed | Threshold | Reasoning |
|---|---|---|---|---|
| ingress | `blocked-total` | 2464 | **4000** | Set ABOVE peak deliberately. Peak is routine IP-reputation scanner volume; 4000 means "well beyond normal sweeps". |
| ingress | `common-ruleset-blocks` | 419 | **700** | ~1.7x peak. The actionable app-probing signal. |
| ingress | `known-bad-inputs-blocks` | 387 | **600** | ~1.5x peak. |
| ingress | `rate-limit-blocks` | 0 | **100** | Never fires; anything sustained is anomalous by definition. |
| scriptcase | `blocked-total` | 297 | **600** | ~2x peak. |
| scriptcase | `common-ruleset-blocks` | 231 | **400** | ~1.7x peak. Dominant blocker on this Web ACL. |
| scriptcase | `known-bad-inputs-blocks` | 107 | **250** | ~2.3x peak; low absolute volume so a wider margin. |
| scriptcase | `rate-limit-blocks` | 0 | **100** | As above. |

`AWS-IPReputation` is deliberately **not alarmed on**. It is the largest block source and almost entirely commodity noise; alarming on it would be pure alert fatigue. It stays visible on the dashboard.

Verify overrides actually took effect rather than silently falling back to defaults:

```bash
cd terraform/live/perimeter/waf-monitoring && terraform output effective_thresholds
```

## Known traffic patterns

Things that look like problems if you do not know they exist:

- **Wazuh internal API** — sends `127.0.0.1` in bodies for health checks and large bodies for index-pattern lookups. Trips `EC2MetaDataSSRF_BODY` and `SizeRestrictions_BODY`, both set to Count on `ingress-alb-waf`. This is the entire `CountedRequests` signal there.
- **Global Accelerator health checks** — probe `:80` on the ingress ALB every 30s and get a 301. Counts as `AllowedRequests`, and is the floor under that metric.
- **Internet scanner background** — constant. `BlockedRequests` has a non-zero floor by design, mostly `AWS-IPReputation`.
- **osTicket attachments** (once live) — large multipart POSTs. `SizeRestrictions_BODY` stays in Count on that Web ACL for this reason.

## Update procedure

1. Re-run the capture block above **in Perimeter**.
2. Replace the tables in "Current baseline".
3. Recompute thresholds if peaks moved materially, and update `waf-monitoring/terraform.tfvars`.
4. Add a changelog line.

Weekly for the first month after a new Web ACL is added, monthly thereafter.

## Changelog

- **2026-08-08** — First real capture. Replaced the placeholder TBDs that had stood since 2026-06-21 (blocked until the CloudWatch namespace defect was fixed and the account-selection error was found). Derived per-Web-ACL thresholds; established that IP-reputation noise dominates ingress and must not be alarmed on.
