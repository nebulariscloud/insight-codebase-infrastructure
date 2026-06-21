# WAF incident response runbook

## When this fires

You'll get an email from `perimeter-waf-high@<account>.sns.us-east-2.amazonaws.com` (subscription confirmed by the security DLs) when one of the High-severity alarms breaches. Possible causes:

- Sustained rate-limit blocks (`*-rate-limit-blocks`) — the most common one. A single source IP or small set of IPs is hitting `2000 req / 5 min / IP`.
- A future high-severity alarm we add (Bot Control challenge spike, IP-reputation block surge, etc.).

Medium-severity alarms (`*-blocked-total`, `*-common-ruleset-blocks`) come in via `perimeter-waf-medium`. Treat these as "look at it within an hour", not "wake someone up".

## First five minutes

1. Open the CloudWatch dashboard `perimeter-waf` (us-east-2).
2. Identify which Web ACL is firing — `ingress-alb-waf` (Wazuh) or `scriptcase-lb-waf` (Scriptcase). The alarm name tells you.
3. On the "blocks by rule" widget for that Web ACL, check which rule line spiked. That tells you the attack class:
   - `RateLimit` — abuse / scraping / brute force from a small IP set
   - `AWS-IPReputation` — known-bad sources (AWS curated)
   - `AWS-CommonRuleSet` — OWASP-style payloads (XSS, RFI, etc.)
   - `AWS-KnownBadInputs` — exploit attempts against common CVEs
4. Sample the actual requests:

   ```bash
   aws wafv2 get-sampled-requests \
     --web-acl-arn $(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
       --query "WebACLs[?Name=='ingress-alb-waf'].ARN | [0]" --output text) \
     --rule-metric-name RateLimit \
     --scope REGIONAL \
     --region us-east-2 \
     --max-items 100 \
     --time-window StartTime=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ),EndTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   ```

   Note the source IPs, URIs, and user-agents.

## Triage — is it real?

| Signal | Likely diagnosis |
|---|---|
| One IP, repetitive URI, low diversity in user-agents | Scraper / brute force. Add to `deny_ip_cidrs` (see "Block an IP" below). |
| Many IPs, common user-agent, common URI | Distributed scraper or low-grade DDoS. Tighten the rate limit or enable Bot Control. |
| Many IPs, randomized URIs, OWASP-style payloads | Real attack pressure. Consider tightening `AWS-CommonRuleSet` overrides — promote any `Count` override back to default Block. |
| Single IP, your own monitoring or deploy tooling | False positive. Add to `allow_ip_cidrs` after confirming the source. |
| Spike correlates with a new release | Bad deploy producing payloads that look hostile. Roll back, then analyse. |

## Block an IP — fast path

This is the day-one motion. The current Web ACLs are CFN-owned, so the fast path is to add the IP via Terraform-owned IPSets that the migrated Web ACLs (or a new Terraform Web ACL) will reference.

Until the Web ACLs are migrated, the runbook for an immediate block is the AWS console:

1. Open WAF → IP sets → us-east-2.
2. Either edit the existing `<webacl>-deny-v4` set if Terraform-managed, or create a temporary IP set.
3. Add the offending CIDR (use a `/32` for a single IP).
4. If a temporary set was needed, attach it to the Web ACL by editing it in the console with priority -5 (before everything else).
5. Open a PR within the next hour to move the change into Terraform — the console change is a stop-gap, not a destination.

After the Web ACL migration to Terraform: edit the `deny_ip_cidrs` list in the relevant leaf, open a PR, merge. CI applies in ~1 minute.

## Allow an IP — fast path

Same pattern as block, but `allow_ip_cidrs`. Caveat: an Allow at priority 0 short-circuits **every** other rule, including the rate limit. Use only for vetted, known-good sources.

## Tune a managed rule false-positive

If `AWS-CommonRuleSet` is blocking legitimate traffic for a specific sub-rule:

1. Confirm with `get-sampled-requests` (above).
2. Identify the sub-rule from the sampled response (it'll be in `RuleNameWithinRuleGroup`).
3. Edit the WAF source for that Web ACL:
   - LZA-owned (current state): edit the `RuleActionOverrides` block in `aws-accelerator-config/custom-stacks/<file>.yaml`. Run the LZA pipeline. ~30 min.
   - Terraform-owned (after migration): add the sub-rule to `common_rule_overrides_to_count` in the leaf. Open PR. ~1 min.

## Roll back the rule set

If a tuning change introduced a regression:

- LZA: revert the customizations-config / custom-stacks YAML and re-run the pipeline.
- Terraform: revert the PR. CI applies the prior state. The Web ACL is updated in place; the underlying ALB and associations stay healthy throughout.

A WAF rule change is not destructive — there is no traffic loss during the swap. Don't hesitate.

## Escalation

- **Sustained High-severity alarm > 30 min** with no actionable signal → escalate to the on-call lead via the security distribution list.
- **Real attack confirmed** → loop in the application owner (Wazuh team for Ingress, Scriptcase owner for Scriptcase). Communicate which IPs were blocked and why, and whether any business traffic was caught up.
- **PCI Web ACL implicated** (when deployed) → also notify compliance, since the PCI account is in scope.

## Post-incident

Open a PR to make any temporary console changes permanent, or document why they weren't needed. Update `docs/waf-traffic-baseline.md` if the incident shifts the normal traffic profile (new partner, new endpoint pattern, etc.).
