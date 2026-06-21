# WAF rule management and tuning guide

## Operating principle

Every new rule starts in `Count` mode. Watch it for at least 7 days. If the false-positive rate is acceptable (subjective — usually "no legitimate traffic blocked, < 1% of real traffic counted"), promote to `Block`. If not, override the noisy sub-rule(s) and try again.

This applies equally to:
- Toggling on a new managed rule group (Bot Control, AnonymousIP)
- Adding a custom rule
- Tightening a rate-limit
- Adding a geo gate

## How to tell if a rule is noisy

Open the dashboard, look at the per-rule panel for the Web ACL. For each rule, compare:

- `BlockedRequests` rate over the last week
- `CountedRequests` rate over the last week (this is what would have been blocked if the rule was promoted)

`get-sampled-requests` per rule shows the actual matches:

```bash
aws wafv2 get-sampled-requests \
  --web-acl-arn <arn> \
  --rule-metric-name AWS-CommonRuleSet \
  --scope REGIONAL \
  --region us-east-2 \
  --max-items 200 \
  --time-window StartTime=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ),EndTime=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  | jq '.SampledRequests[] | {URI: .Request.URI, Action: .Action, RuleNameWithinRuleGroup: .RuleNameWithinRuleGroup, ClientIP: .Request.ClientIP}'
```

`RuleNameWithinRuleGroup` is the sub-rule name you'd add to `common_rule_overrides_to_count` (or `bot_control_overrides_to_count`).

## Sub-rules that are commonly false-positive in this estate

These are already overridden to `Count` on `ingress-alb-waf` because of Wazuh's API behavior:

| Sub-rule | Why it false-positives on Wazuh |
|---|---|
| `EC2MetaDataSSRF_BODY` | Wazuh sends `127.0.0.1` and similar in legitimate health-check bodies. |
| `SizeRestrictions_BODY` | Index-pattern lookups send large JSON bodies. |
| `GenericRFI_BODY` | URL-like values appear in Wazuh agent payloads. |
| `GenericRFI_QUERYARGUMENTS` | Same as above, in query strings. |

Scriptcase and PCI templates do not have these overrides today. If Scriptcase tuning surfaces the same patterns, port the override over.

## Bot Control — the special case

Bot Control charges per Web ACL per month plus per request inspected. Don't enable it until you're ready to commit to:

1. Deploy in Count mode for at least 7 days on one Web ACL (recommend Scriptcase first — smaller, simpler traffic profile than Ingress).
2. Watch the dashboard. The most common false-positives are:
   - `SignalAutomatedBrowser` — flags any client that looks "scripted". Catches legitimate Selenium-based monitoring.
   - `CategoryHttpLibrary` — flags requests from `requests`, `curl`, etc. Catches legitimate API consumers.
3. Override those to Count if they're firing on legitimate traffic. Re-baseline.
4. Once Count mode is clean for 7 days, promote to default actions.
5. Only then enable on the second Web ACL.

`COMMON` inspection level is the cheaper tier and what to start with. `TARGETED` adds ML signals and CAPTCHA / challenge actions and roughly doubles the per-request cost. Don't promote to `TARGETED` without a specific reason.

## Rate-limit tuning

Default is `2000 req / 5 min / IP` on Ingress and Scriptcase, `500 / 5 min / IP` on PCI.

To tune:

1. Pull the rate-limit alarm history. If it never fires, the threshold is too loose. If it fires multiple times a week with no real attack pressure, it's too tight.
2. Sample the rate-limited requests to see who's hitting the cap. If the source is legitimate (synthetic monitor, partner's own egress, etc.), put them in `allow_ip_cidrs` rather than raising the global cap.
3. Per-path rate limits (e.g. `/login`, `/api`) are often a better fit than raising the global cap. Add via `custom_rules` with `rate_based_statement.scope_down_uri_starts_with`.

## Geo gating

Don't deploy unless the business answer to "what countries do we legitimately serve?" is crisp. A wrong geo gate is the easiest way to block a paying customer. When in doubt, leave both `geo_allow_country_codes` and `geo_block_country_codes` empty.

If you do deploy, prefer `geo_allow_country_codes` (positive list) over `geo_block_country_codes` (negative list). Smaller, more auditable surface.

## How to promote a Count override back to Block

Reverse of the Count process:

1. Confirm in the dashboard that the rule has been Count'd cleanly for at least 7 days (no real false-positives in `get-sampled-requests`).
2. Remove the sub-rule from `common_rule_overrides_to_count` (or wherever you added it).
3. Open a PR. CI applies in ~1 min for Terraform-managed Web ACLs, ~30 min for LZA.
4. Watch the dashboard for the next 24 hours. Roll back if real false-positives appear.

## Logging and analysis

WAF logs land in `s3://aws-waf-logs-<account>-<region>/AWSLogs/<account>/WAFLogs/<region>/<webacl>/<year>/<month>/<day>/<hour>/`.

Build an Athena table over them with the standard partition projection from `https://docs.aws.amazon.com/waf/latest/developerguide/logging-querying.html`. The schema doesn't need customization. Useful queries:

- Top 20 source IPs in the last hour.
- Top 20 URIs that triggered `Action = BLOCK` in the last day.
- Per-rule block count over the last week (cross-check against the dashboard).

Keep the Athena workspace pointed at the WAF logs bucket; don't reuse the LZA central log bucket.

## When to add a custom rule vs a managed group

- Managed group covers a generic class of attack (OWASP, exploits, bad inputs, IP reputation). Use these first.
- Custom rule covers a specific application pattern (a path that should never receive a certain header, a known-bad query parameter, a tighter rate limit on `/login`). Use these to cover what the managed groups miss.

A custom rule that duplicates what a managed group already does is dead code — it'll trigger after the managed rule has already blocked. Always check the rule evaluation order before adding a custom rule.
