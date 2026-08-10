# SOW closeout — AWS WAF Implementation

| Field | Value |
|---|---|
| Project | AWS WAF Implementation |
| Client | Insight Group |
| Service Provider | Nebularis Cloud LLC |
| SOW dated | March 5, 2026 |
| SOW value | $8,500 (50% on signing, 50% on completion) |
| Original closeout | June 21, 2026 |
| **Revised** | **August 10, 2026 — see "Revision history"** |
| Status | **Substantially complete. Four items open, listed in "What remains".** |
| Repository | `nebulariscloud/insight-codebase-infrastructure` |
| Account in scope | Perimeter `713939170920`, us-east-2 |

---

## Revision history — why this document changed

**This document was revised on 2026-08-10 because the June version asserted something that was not true.**

The June closeout recorded the CloudWatch monitoring and alerting as delivered and verified. It was neither. The `waf-monitoring` Terraform module specified the metrics namespace as `AWS/WAFv2` (lowercase `v`); the actual namespace is `AWS/WAFV2`, and CloudWatch namespaces are case-sensitive. Every alarm therefore resolved against a namespace containing zero metrics.

Because all the threshold alarms use `treat_missing_data = "notBreaching"`, an alarm watching a non-existent metric reports `OK` — indistinguishable from a healthy one. The June verification observed eight green alarms and concluded the pipeline worked. That inference was invalid.

**Consequence:** from 2026-06-21 to 2026-08-10 the WAF alarms could not fire under any circumstances, and the CloudWatch dashboard rendered empty.

**What was NOT affected:** WAF inspected every request, enforced every rule, and delivered logs to S3 correctly throughout. The protection worked. The notification about it did not.

**What went unreported during the gap.** Two genuine threshold breaches on `ingress-alb-waf`:

| Window | Blocked / 5 min |
|---|---|
| 2026-08-06 19:23 → 19:28 | 1958, then 1055 |
| 2026-08-07 00:23 → 00:28 | 2225, then 1081 |

Both exceeded the configured threshold across two consecutive periods and should have alarmed. Per-rule analysis shows both were approximately 65% `AWS-IPReputation` — AWS's curated known-bad-IP list catching botnet and mass-scanner traffic, which WAF blocked correctly. **There is no evidence of an unhandled targeted attack during the gap.**

**Remediation completed 2026-08-10.** Namespace corrected. A dead-man's-switch alarm added per Web ACL (`AllowedRequests < 1` with `treat_missing_data = "breaching"`) so that "this alarm is watching nothing" becomes a firing condition rather than a silent pass. Verification rewritten to assert on datapoints rather than alarm state. Full detail in `waf-verification-record.md` (V3 retraction and V3-R) and `waf-design-decisions.md` (D13).

---

## Acceptance criteria — current status

### 1. AWS WAF deployed and actively protecting all designated resources

**Met.** Verified 2026-08-10 in Perimeter `713939170920` via `get-web-acl-for-resource`:

```
ingress-alb    WAF=ingress-alb-waf
scriptcase-lb  WAF=scriptcase-lb-waf
crm-alb        WAF=crm-alb-waf
osticket-alb   WAF=osticket-alb-waf
```

Note this is **four** ALBs, not the two that existed at SOW signing. `crm-alb` and `osticket-alb` were built after the June closeout and had no WAF until 2026-08-10. They were internet-facing on `0.0.0.0/0` in the interim. Now protected.

### 2. OWASP Top 10 threats blocked by managed rules

**Met.** `AWSManagedRulesCommonRuleSet` and `AWSManagedRulesKnownBadInputsRuleSet` active on all four Web ACLs, plus `AWSManagedRulesAmazonIpReputationList`. The PCI template additionally carries `SQLiRuleSet` and `LinuxRuleSet`.

### 3. Bot control and rate limiting operational

**Rate limiting: met.** 2000 req/5 min/IP on all four Web ACLs. Measured over four days: the rate-based rule produced **zero** datapoints, confirming it is not false-positiving and nothing legitimate is reaching the cap.

**Bot Control: NOT DEPLOYED — open item 1.** See "What remains".

### 4. Monitoring dashboard showing real-time traffic and blocks

**Met, pending visual confirmation.** Dashboard `perimeter-waf` exists with one row per Web ACL plus a rollup. It rendered empty until the namespace fix on 2026-08-10; the metrics it queries are now confirmed present (500,210 metrics in `AWS/WAFV2`, with real datapoints on the exact dimension set the widgets use).

**A human should open it once and confirm the widgets populate.** That is the last unverified step on this criterion.

Alarming is fully operational — 20 alarms across 4 Web ACLs (blocked-total, common-ruleset, known-bad-inputs, rate-limit, and a liveness alarm each), routed to three severity-tiered SNS topics subscribed to the `insightgroup-security-{high,medium,low}@nebulariscloud.com` distribution lists.

### 5. No false positives affecting legitimate business traffic

**Met for all observed traffic.** Count overrides tuned for the Wazuh API's behaviour (`EC2MetaDataSSRF_BODY`, `SizeRestrictions_BODY`, `GenericRFI_BODY`, `GenericRFI_QUERYARGUMENTS`) and for osTicket file attachments. Rate limiting never triggered. No false-positive reports.

As noted at the original closeout, "zero false positives" is unprovable in absolute terms and is operationalised as: no false positives on validated traffic, with a documented tuning path for any that appear.

---

## Deliverables — current status

### System & architecture

| Deliverable | Status |
|---|---|
| AWS WAF Web ACLs configured and associated | **Delivered** — 4 live, 1 template ready (PCI) |
| Managed rule groups deployed and tuned | **Delivered** |
| Custom rules for application-specific protection | **Capability delivered, no rules defined — open item 4** |
| Rate limiting configuration | **Delivered** |
| AWS WAF Bot Control configuration | **Capability delivered, not enabled — open item 1** |
| CloudWatch monitoring and alerting setup | **Delivered** (see revision history) |

### Documentation

All in `docs/waf/`.

| Deliverable | File | Status |
|---|---|---|
| WAF architecture and rule documentation | `waf-architecture.md` | Delivered |
| Incident response runbook | `waf-runbook.md` | **Written; not yet exercised — open item 3** |
| Rule tuning and management guide | `waf-tuning-guide.md` | Delivered |
| Traffic baseline and threshold documentation | `waf-traffic-baseline.md` | Delivered with measured data |
| Design decisions record (beyond SOW) | `waf-design-decisions.md` | Delivered — 13 ADRs |
| Verification record (beyond SOW) | `waf-verification-record.md` | Delivered |

### Training

| Deliverable | Status |
|---|---|
| Security operations walkthrough | **Not delivered — open item 2** |
| Rule management and tuning training | **Not delivered — open item 2** |

---

## What remains

Four items. **None are blocked on engineering work.**

### Open item 1 — Bot Control: decision required from Insight Group

Bot Control appears in the SOW objectives, success metrics, deliverables and acceptance criteria. It is the only substantive technical gap.

It is not enabled because it is a recurring cost and carries false-positive risk:

- **Cost:** ~$10 per Web ACL per month, plus per-request inspection fees. Across four Web ACLs, roughly $40/month before request volume.
- **Risk:** the `SignalAutomatedBrowser` and `CategoryHttpLibrary` sub-rules commonly fire on legitimate traffic — synthetic monitoring, and API consumers using `requests` or `curl`. The CRM ALB fronts exactly that kind of client.

**Two valid resolutions:**

**(a) Deploy it.** Procedure already written in `waf-tuning-guide.md`: enable in Count mode on `scriptcase-lb-waf` first (smallest, simplest traffic profile), observe for one week, override any sub-rules firing on legitimate traffic, promote to Block, then extend to the other Web ACLs one at a time. Estimated one week, mostly observation. The Terraform module already supports it via `enable_bot_control`, `bot_control_inspection_level` and `bot_control_overrides_to_count` — no new engineering.

**(b) Formally waive it.** If Insight Group would rather not carry the cost, this needs a written SOW amendment recording the waiver, so the deliverable is dispositioned rather than silently unmet.

**Recommendation:** option (a), starting with Scriptcase. It is a public PHP application and the most likely of the four to attract scrapers and automated abuse.

### Open item 2 — Training: two sessions to schedule

Both are process, not code. The written guides are designed to serve as the scripts.

| Session | Audience | Script | Duration |
|---|---|---|---|
| Security operations walkthrough | Security team / on-call | `waf-runbook.md` | ~1 hour |
| Rule management and tuning | Engineering | `waf-tuning-guide.md` | ~1 hour |

Suggested walkthrough agenda: what each alarm means and which are actionable, how to read the dashboard, the triage table, how to block or allow an IP through the PR flow, and when to escalate.

Suggested tuning agenda: the rule evaluation order, why `AWS-IPReputation` is deliberately not alarmed on, the Count-then-promote discipline, the false-positive workflow, and how to add a per-path rate limit.

### Open item 3 — Test the incident response runbook

The acceptance criterion says "tested and validated". The runbook is written but has not been exercised.

**Suggested test, ~30 minutes:**

1. Pick a harmless source IP you control.
2. Add it to a deny IPSet through the normal PR flow.
3. Confirm from that source that requests are blocked.
4. Confirm the block appears in the WAF logs in `aws-waf-logs-713939170920-us-east-2`.
5. Confirm the relevant CloudWatch metric increments.
6. Remove it via a second PR.
7. Record the outcome and elapsed time at the bottom of `waf-runbook.md`.

This exercises the real response path — PR flow, guard, apply, logging, metrics — rather than just confirming the document reads well. It would also have caught the monitoring defect had it been done in June.

### Open item 4 — Custom rules: review and record the finding

The deliverable is worded as an artefact ("custom rules for application-specific protection"), and currently there are none.

That may be the correct answer. Four days of traffic surfaced no application-specific abuse pattern that the managed rule groups do not already cover. But "we reviewed and concluded none are required" has to be written down rather than left as an absence.

**Suggested closure:** a short conversation with the owners of Wazuh, Scriptcase, the CRM API and osTicket asking whether they know of any app-specific abuse patterns — credential stuffing on a particular endpoint, a scraped path, an API consumer that needs its own rate limit. Then either add rules via the module's `custom_rules` input, or record the finding in `waf-architecture.md`.

Worth noting the module already supports per-path rate limiting, which is the most likely thing to come out of that conversation (for example a tighter limit on osTicket's login).

---

## Items outside SOW scope

Recorded so they are not mistaken for gaps.

| Item | Why out of scope |
|---|---|
| CloudFront integration | The SOW anticipated it, but **no CloudFront distributions exist** in this estate. The `waf-managed` module supports `scope = "CLOUDFRONT"` so the pattern is ready if one is ever created. |
| API Gateway / AppSync protection | No API Gateway or AppSync resources exist. |
| Geo-blocking | SOW says "if required". Capability built (`geo_allow_country_codes` / `geo_block_country_codes`), not deployed — no crisp business answer yet on which countries the applications serve. Deploying a geo gate without that is the fastest way to block a paying customer. |
| AWS Shield Advanced | Not in the SOW. Separate ~$3,000/month subscription decision. |
| PCI ALB deployment | Not an SOW deliverable. Template and PCI-tuned Web ACL are built and ready; the PCI account and VPC exist but hold no workload, no ACM certificate and no ALB. Deploying now would mean paying for a load balancer fronting nothing. |
| Athena analytics over WAF logs | Not in the SOW. The log bucket is structured for it; standard AWS partition-projection schema applies. |

---

## Delivered beyond scope

Not requested in the SOW. Produced in response to failures encountered during delivery, and arguably of more lasting value than the threshold tuning.

| Item | Why it exists |
|---|---|
| **Destroy guard** in CI | A fan-out apply destroyed an unrelated production EC2 instance on 2026-08-08. The pipeline now refuses any apply whose plan deletes or replaces a resource without explicit per-leaf authorisation. |
| **Plan-then-apply-that-plan** | The apply job ran `terraform apply -auto-approve`, which re-plans internally and applies whatever it finds — nobody ever saw the diff. It now applies a saved, inspected plan file. |
| **Concurrency group** | Two overlapping fan-out runs raced for the same DynamoDB state locks. Runs now queue. |
| **Dispatch-apply** | A failed or cancelled apply previously left drift with no way to re-drive except a dummy commit. A single leaf can now be applied on demand, still gated and still guarded. |
| **`.tf-skip` leaf parking** | One un-plannable leaf turned every module PR red, which trains people to ignore failures. Leaves can now be explicitly parked with a documented reason. |
| **Dead-man's-switch alarms** | Encodes the lesson from the namespace defect: a monitoring stack must be able to report that it is itself broken. |
| **Design decisions record** | 13 ADRs covering why each choice was made and what was rejected. |
| **Verification record** | Auditable command-and-output trail, including a retraction where an earlier conclusion proved wrong. |

---

## Completion checklist

Sign-off ready when all four are closed.

- [ ] **Bot Control** — Insight Group decides: deploy (Count → promote, per `waf-tuning-guide.md`) or waive via written SOW amendment
- [ ] **Security operations walkthrough** delivered (~1 hr, script: `waf-runbook.md`)
- [ ] **Rule management and tuning training** delivered (~1 hr, script: `waf-tuning-guide.md`)
- [ ] **Runbook tested** — block/unblock exercise, outcome recorded in `waf-runbook.md`
- [ ] **Custom rules reviewed** — rules added, or finding recorded in `waf-architecture.md`
- [ ] **Dashboard opened and confirmed populating** (last unverified step on acceptance criterion 4)

Operational follow-ups, not SOW blockers:

- [ ] Capture traffic baselines for `crm-alb-waf` and `osticket-alb-waf` after a week, replace their module-default thresholds
- [ ] osTicket ACM certificate `8c2c365f-a408-4bbf-8f6e-187a28665057` — add validation CNAME at Network Solutions, then set `enable_https = true`. **The ticket portal is currently served over plain HTTP.**
- [ ] Tag long-lived migration targets `BackupPlan = Continuous` so they land in the LZA backup vault

---

## Payment

The first 50% was issued on signing per the SOW.

The remaining 50% is contingent on the "50% upon completion" term. Nebularis's position: the technical implementation is complete and verified, with four non-engineering items outstanding — a client decision on Bot Control, two training sessions, a runbook exercise, and a written custom-rules finding. We propose either (a) invoicing on completion of the checklist above, or (b) invoicing now against a written agreement covering the four remaining items, at Insight Group's preference.

## Sign-off

| Role | Name | Date |
|---|---|---|
| Service Provider — Nebularis Cloud LLC | _____________________ | _____________ |
| Client — Insight Group | _____________________ | _____________ |

By signing, both parties acknowledge the monitoring gap described in "Revision history" and its remediation.

---

*Reference: SOW "AWS WAF Implementation," dated March 5, 2026, between Nebularis Cloud LLC and Insight Communications Corp.*
