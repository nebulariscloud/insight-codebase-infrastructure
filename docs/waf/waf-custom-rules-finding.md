# Custom rules — review and finding

Closes SOW deliverable *"Custom rules for application-specific protection"*.

**Status: DRAFT — needs the app-owner conversations before it can be signed off.**

The SOW words this deliverable as an artefact, and there are currently no custom rules deployed. That may well be the right answer, but "we reviewed and concluded none are needed" has to be a recorded finding rather than an absence. This document is the record.

---

## What the managed rules already cover

Before asking for custom rules, it's worth being clear about what would be redundant. All four Web ACLs already run:

| Rule group | Covers |
|---|---|
| `AWSManagedRulesCommonRuleSet` | OWASP-style: XSS, LFI/RFI, bad request patterns, size constraints |
| `AWSManagedRulesKnownBadInputsRuleSet` | Known exploit payloads against common CVEs |
| `AWSManagedRulesAmazonIpReputationList` | AWS-curated malicious source IPs |
| Rate-based rule | 2000 requests / 5 min / source IP |

A custom rule duplicating any of these is dead code — it evaluates after the managed rule has already blocked. Custom rules are for what those miss: **application-specific** patterns.

---

## Evidence from measured traffic

Four days of production traffic, captured 2026-08-10 (full detail in `waf-traffic-baseline.md`):

- **The rate limit never fired.** Zero datapoints on both measured Web ACLs. Nothing is approaching 2000 req/5min/IP.
- **Blocks are dominated by commodity scanning.** ~65% of blocks on `ingress-alb-waf` are IP reputation — botnets and internet-wide scanners, not targeted probing.
- **No repeated pattern against a single endpoint** appeared in sampled requests that the managed groups weren't already catching.
- **Scriptcase shows proportionally more app-layer probing** (CommonRuleSet 231 vs IPReputation 182) than Ingress. Consistent with it being a public PHP app. Still handled by the managed rules.

**On the evidence alone, no custom rule is currently justified.** But four days of traffic cannot reveal an abuse pattern the app owners already know about, which is what the conversations are for.

---

## Questions for each application owner

Four questions. The answers determine whether any rules get written.

1. **Is any endpoint seeing credential stuffing or brute force?** Login pages, API token endpoints, password reset.
2. **Is any path being scraped?** Repeated automated retrieval of the same resource.
3. **Does any API consumer need its own rate limit?** Either a partner who should be capped tighter, or an integration that legitimately bursts and needs the global limit relaxed for it.
4. **Any known-bad user-agent, header or query pattern?** Something you already filter at the app layer that would be cheaper to block at the edge.

### Owner sign-off

| Application | Web ACL | Owner | Date | Any rules needed? |
|---|---|---|---|---|
| Wazuh (dashboard + API) | `ingress-alb-waf` | ____________ | ________ | ☐ No ☐ Yes → below |
| Scriptcase | `scriptcase-lb-waf` | ____________ | ________ | ☐ No ☐ Yes → below |
| ICC CRM API (prod + dev) | `crm-alb-waf` | ____________ | ________ | ☐ No ☐ Yes → below |
| osTicket | `osticket-alb-waf` | ____________ | ________ | ☐ No ☐ Yes → below |

---

## Rules identified

*(Fill in per application, or leave empty and record the no-rules finding below.)*

| # | Application | Pattern to address | Proposed rule | Priority |
|---|---|---|---|---|
| | | | | |

---

## Most likely candidate, if any

Based on the applications in scope, the single most probable useful rule is a **tighter per-path rate limit on a login endpoint** — osTicket's `/scp/login.php` being the obvious one, since a public ticket portal is a standard credential-stuffing target and the global 2000/5min limit is far too loose to stop a patient attacker.

That would look like:

```hcl
  custom_rules = [
    {
      name     = "OsticketLoginRateLimit"
      priority = 100
      action   = "block"
      rate_based_statement = {
        limit                      = 100
        aggregate_key_type         = "IP"
        scope_down_uri_starts_with = "/scp/login.php"
      }
    },
  ]
```

Deploy it in `count` first, as with any new rule — see `waf-tuning-guide.md`. Confirm the real login volume from the baseline before fixing the limit; 100 is a placeholder, not a recommendation.

---

## Finding

*(Complete one of the two. Then tick item 4 in `waf-finish-checklist.md`.)*

### Option A — no custom rules required

> Reviewed on ____________ with the owners of Wazuh, Scriptcase, the ICC CRM API and osTicket. No application-specific abuse patterns were identified beyond what the AWS managed rule groups already cover, and four days of measured production traffic showed none. **No custom rules are deployed.**
>
> The `waf-managed` module supports them via its `custom_rules` input if this changes. Revisit if any application reports abuse that the managed groups do not catch, or at the next annual review.
>
> Recorded by: ____________

### Option B — rules identified and deployed

> Reviewed on ____________ with the owners listed above. The rules in "Rules identified" were deployed via PR #____ and are running in Count mode from ____________, to be promoted to Block after one week of clean observation.
>
> Recorded by: ____________

---

## After completing this

1. Tick item 4 in `waf-finish-checklist.md`.
2. Summarise the outcome in one line in `waf-architecture.md` under a **Custom rules** heading, so someone reading the architecture doc doesn't have to find this file.
3. If rules were deployed, add them to the rule-evaluation-order table in `waf-architecture.md`.
