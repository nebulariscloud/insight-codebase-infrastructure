# SOW closeout — AWS WAF Implementation

| Field | Value |
|---|---|
| Project | AWS WAF Implementation |
| Client | Insight Group |
| Service Provider | Nebularis Cloud LLC |
| SOW dated | March 5, 2026 |
| SOW value | $8,500 (50% on signing, 50% on completion) |
| Original closeout | June 21, 2026 |
| **Revised** | **August 10, 2026 (rev 2 and rev 3) — see "Revision history"** |
| Status | **Substantially complete. Four SOW items open, plus one logging fix in review and two verification gaps — all listed below.** |
| Verification report | `waf-verification-report.md` — the client-facing record of every check |
| Repository | `nebulariscloud/insight-codebase-infrastructure` |
| Account in scope | Perimeter `713939170920`, us-east-2 |

---

## Revision history — why this document changed

| Rev | Date | What changed |
|---|---|---|
| 1 | 2026-06-21 | Original closeout |
| 2 | 2026-08-10 | Monitoring correction — the namespace defect. Below. |
| 3 | 2026-08-10 | Logging coverage gap and orphaned state file, found by a deeper verification round the same day. Below. |
| 3a | 2026-08-10 | Rev 3 outcomes: logging fix applied, alarm inventory confirmed at 20, and the orphaned state confirmed **not** to be a live unprotected load balancer. Below. |

Full evidence for all of it, command by command, is in
`waf-verification-report.md` (client summary) and `waf-verification-record.md`
(raw commands and output).

---

### Rev 3a — how the rev 3 findings resolved, 2026-08-10

All three were chased the same day. Outcomes:

| Finding | Outcome |
|---|---|
| 1 — two Web ACLs never logging | **Fixed and fully verified.** PR #69 merged and applied; plan was `2 to add, 0 to change, 0 to destroy` as predicted. All four Web ACLs now delivering log records: 28830 / 15502 / 1 / 4. |
| 2 — orphaned `icc-alb` state | **Closed.** Account-wide enumeration returned seven load balancers: three network (WAF does not apply to NLBs) and four application, every one with a Web ACL. No `icc-alb`. Resolved to a destroyed load balancer — the state's DNS name `icc-alb-396237492...` differs from the live `crm-alb-142110994...`, so `crm-alb` was rebuilt rather than renamed. The destroy had been partial, leaving `icc-alb-sg` (`sg-076c916a807936cee`) unmanaged; that security group and the stale state object were both removed on 2026-08-10, with a backup of the state taken first. Certificate inventory afterwards clean — four certificates, all accounted for. |
| 3 — alarm inventory unconfirmed | **Confirmed: 20 alarms.** The six-alarm capture predated PR #62's apply; it was a stale reading, not a failed apply. |

**Net effect on this closeout.** Acceptance criterion 1 loses its qualification — the load balancer inventory is now known complete, so "all four ALBs protected" is unconditional rather than a statement about the ALBs we knew of. The logging deliverable goes from 2-of-4 to **4-of-4 configured and confirmed delivering**. Monitoring is fully verified.

**All three rev 3 findings are closed, and the state cleanup with them.** What remains on the Nebularis side is a single item that was never a failure: exercising the incident response runbook.

**One finding outside SOW scope, recorded because it surfaced during this work and matters more than anything left inside scope.**

The forced request that closed the logging check returned HTTP **500** from osTicket. Chased down, it turned out to be two separate problems:

1. **The osTicket target group has been unhealthy the entire time** (`Target.ResponseCodeMismatch`), and the load balancer has been serving traffic anyway. ALB health checks address the target by IP, ELBv2 offers no way to set the hostname they send, and osTicket answers an unrecognised host with 500 — outside the configured `200,301,302` matcher. Traffic still flowed because when every target in a group is unhealthy the ALB routes to all of them regardless. One target, so it failed open, silently.
2. **osTicket redirects to `https://osticket.insightgrouppr.com/`, and the load balancer has no HTTPS listener** — `enable_https = false`, so no certificate, so no port-443 listener. Every browser following that redirect reaches a closed port. **The portal is unusable through this load balancer.**

**Not a live outage.** `osticket.insightgrouppr.com` has not been pointed at this load balancer, and the certificate validation record is deliberately being held until the cutover window. The help desk is still served by the pre-migration host, so both faults are latent.

**This is not a WAF defect.** The Web ACL inspects and logs that traffic correctly, which acceptance criterion 1 and the logging verification both confirm.

Two consequences that do bear on this document:

**1. `osticket-alb-waf` is not yet in front of real user traffic.** It is deployed, attached, logging and alarming, and acceptance criterion 1 is met on the load balancer. But until DNS moves, what it inspects is test traffic. Stated plainly so that "all four applications protected" is not read as "the osTicket application is protected today" — the load balancer is ready; the traffic has not arrived. The same is true in a narrower sense of any application whose DNS has not yet moved.

**2. Both faults must close before the cutover.** Move DNS with either still in place and the help desk breaks at the worst possible moment. The ordering — validation CNAME, then `enable_https = true`, then the health-check fix, then DNS — is written up at step 8d of `waf-finish-checklist.md`. All three preparatory steps are reversible and none touch the currently-live help desk, so they belong ahead of the cutover window rather than inside it.

The health-check fix is a static file the web server answers for any hostname — deliberately **not** widening the accepted status codes to include 500, which would make the check pass while osTicket was genuinely broken and repeat the rev 2 mistake of a monitor that cannot report failure.

**Belongs to the osTicket migration workstream, not this SOW.** Recorded here because it was found during WAF verification and because it changes how acceptance criterion 1 should be read for that one application.

**No open security exposure remains in the WAF layer.** The one live exposure on the list is unrelated to WAF: the osTicket portal is served over plain HTTP, blocked on a DNS record only Insight Group can create.

An incidental benefit: chasing finding 2 is what produced the account-wide load balancer enumeration in the first place. Without it, acceptance criterion 1 would still rest on a list of ALBs assembled from the Terraform leaves rather than from AWS.

---

### Rev 3 — two further findings, 2026-08-10

Immediately after rev 2 we ran a wider verification round rather than stopping at
the namespace fix. It found two more things. Both are recorded here because the
alternative is that Insight Group finds them later.

**Finding 1 — two of four protected resources were never logging.**

```
ingress-alb-waf      log objects=28812
scriptcase-lb-waf    log objects=15492
crm-alb-waf          log objects=0
osticket-alb-waf     log objects=0
```

`crm-alb-waf` and `osticket-alb-waf` have delivered zero WAF log records since
their creation in July. The `waf-logs` Terraform leaf took one variable per Web
ACL with no way to express a third or fourth, so when those two ALBs were built
and given Web ACLs there was no mechanism to enrol them. Nothing failed. The leaf
planned clean and applied clean the whole time.

This affects the SOW deliverable *"Configure WAF logging to S3 and CloudWatch
Logs."* Two of four protected resources were outside it. **This is a delivery
miss on Nebularis's side, not a change request** — and it had additionally been
characterised in our internal notes as an optional refactor, which was wrong.

Structurally it is the same failure as the namespace defect: an uncovered case
that produced no error signal.

Fix in review as **PR #69**. Create-only plan — the log destination module keys
its resources by Web ACL ARN, so the two working configurations are untouched.

**Finding 2 — an orphaned Terraform state file claiming 13 live resources.**

`crm-alb` was renamed from `icc-alb` in PR #45; the old state object was never
removed. It still claims a load balancer, a security group, an ACM certificate,
two target groups and two listener rules. No live leaf points at it.

Either those are the same resources `crm-alb` now manages — a dual-management
hazard with no extra cost or exposure — or a separate `icc-alb` load balancer is
still running, internet-facing and outside the WAF programme. **We have not yet
determined which.** One API call settles it; it is step 7 of
`waf-finish-checklist.md`.

Until it is settled, acceptance criterion 1 below reads as "all four *known*
ALBs are protected".

**Finding 3 — the expanded alarm inventory is not confirmed.**

PR #62 expanded the alarm set from 6 to an expected 20. Our internal notes record
that as verified; a later capture showed only the original 6 names. We cannot
reconcile the two, so we are **not** claiming it. One command settles it —
checklist step 6b. Called out rather than quietly resolved, because treating
unconfirmed monitoring as confirmed is exactly what rev 2 was about.

---

### Rev 2 — the monitoring correction

**The June version asserted something that was not true.**

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

The ALB list was enumerated from AWS via `describe-load-balancers`, not read off the Terraform leaves, so an ALB created outside the WAF programme would have shown up.

**Confirmed complete.** The account holds seven load balancers:

| Load balancer | Type | WAF |
|---|---|---|
| `ingress-alb` | application | `ingress-alb-waf` |
| `scriptcase-lb` | application | `scriptcase-lb-waf` |
| `crm-alb` | application | `crm-alb-waf` |
| `osticket-alb` | application | `osticket-alb-waf` |
| `sftp-nlb` | network | n/a |
| `sftp-claro-nlb` | network | n/a |
| `wazuh-nlb` | network | n/a |

Every application load balancer has a Web ACL. The three NLBs cannot have one — AWS WAF is a layer-7 control and does not attach to Network Load Balancers. Those carry TCP services (SFTP, Wazuh agent traffic), not HTTP, so WAF is not the applicable control; their exposure is managed by security-group scoping.

The first draft of this revision qualified the result as "all four *known* ALBs" pending the orphaned-state question. **That qualification is lifted** — the enumeration is account-wide, so the inventory is known complete.

### 2. OWASP Top 10 threats blocked by managed rules

**Met.** `AWSManagedRulesCommonRuleSet` and `AWSManagedRulesKnownBadInputsRuleSet` active on all four Web ACLs, plus `AWSManagedRulesAmazonIpReputationList`. The PCI template additionally carries `SQLiRuleSet` and `LinuxRuleSet`.

### 3. Bot control and rate limiting operational

**Rate limiting: met.** 2000 req/5 min/IP on all four Web ACLs. Measured over four days: the rate-based rule produced **zero** datapoints, confirming it is not false-positiving and nothing legitimate is reaching the cap.

**Bot Control: NOT DEPLOYED — open item 1.** See "What remains".

### 4. Monitoring dashboard showing real-time traffic and blocks

**Fully met.** Verified 2026-08-10 on three counts, in Perimeter `713939170920` / us-east-2:

| Check | Result |
|---|---|
| Dashboard `perimeter-waf` exists, post-dating the namespace fix | `LastModified 2026-08-10T18:11:59` |
| Widget definitions query the corrected namespace | Body references only `AWS/WAFV2` |
| Widgets visibly render data | **Confirmed in the console** — populated, graphs showing traffic |

One row of widgets per Web ACL plus a rollup row. It rendered empty from June until the namespace fix; the metrics behind it are confirmed present (500,210 metrics in `AWS/WAFV2`, real datapoints on the exact dimension set the widgets query), and a person has now confirmed it displays them.

**This was the last unverified item on this criterion.** It needed a human rather than a command, because a dashboard can exist, hold correct definitions and sit in front of live metrics while still rendering nothing useful — and "it exists" was exactly the inference that made the June verification wrong.

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
| CloudWatch monitoring and alerting setup | **Delivered and verified** — 20 alarms confirmed 2026-08-10 (see rev 2 and rev 3a) |
| WAF logging to S3 | **Delivered and verified for all 4 Web ACLs** — PR #69 merged and applied 2026-08-10; all four confirmed delivering log records. S3-only by design (D2); the SOW's "and CloudWatch Logs" is a deliberate omission on cost and SCP grounds, not a gap |

### Documentation

All in `docs/waf/`.

| Deliverable | File | Status |
|---|---|---|
| WAF architecture and rule documentation | `waf-architecture.md` | Delivered |
| Incident response runbook | `waf-runbook.md` | **Written; not yet exercised — open item 3** |
| Rule tuning and management guide | `waf-tuning-guide.md` | Delivered |
| Traffic baseline and threshold documentation | `waf-traffic-baseline.md` | Delivered with measured data |
| Design decisions record (beyond SOW) | `waf-design-decisions.md` | Delivered — 14 ADRs |
| Verification record (beyond SOW) | `waf-verification-record.md` | Delivered — 11 checks across 3 rounds, raw command output |
| Verification report for Insight Group (beyond SOW) | `waf-verification-report.md` | Delivered — client-facing summary of every check plus four corrections to our own record |

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

Copy-paste commands for each of these are in `waf-finish-checklist.md`.

**Nebularis to close — engineering, no client input needed:**

- [x] **PR #69 merged and applied** — logging enrolled for `crm-alb-waf` and `osticket-alb-waf` (rev 3 finding 1). Applied 2026-08-10.
- [x] **Alarm inventory confirmed** — 20 alarms (rev 3 finding 3). Confirmed 2026-08-10.
- [x] **No unprotected load balancer** — account-wide enumeration, 4 of 4 ALBs with a Web ACL, no `icc-alb` (rev 3 finding 2, the material half).
- [x] **Log delivery verified on all four Web ACLs** — 28830 / 15502 / 1 / 4. **The logging deliverable is closed.**
- [x] **Dashboard opened and confirmed populating** — done 2026-08-10. **Acceptance criterion 4 fully met.**
- [ ] **Runbook tested** — block/unblock exercise, outcome recorded in `waf-runbook.md`
- [x] **Orphaned `icc-alb` security group and state object removed** — completed 2026-08-10. `delete-security-group` returned success rather than `DependencyViolation`, confirming nothing referenced it.
- [ ] **osTicket cutover prerequisites** — not a WAF item and not currently user-facing. Target group unhealthy behind a fail-open load balancer, and a redirect to an HTTPS listener that does not exist. Both must close before DNS moves. Checklist step 8d; tracked on the osTicket migration checklist.

**Requires Insight Group:**

- [ ] **Bot Control** — decide: deploy (Count → promote, per `waf-tuning-guide.md`) or waive via written SOW amendment
- [ ] **Custom rules** — four short owner conversations (Wazuh, Scriptcase, CRM API, osTicket), then rules added or finding recorded per `waf-custom-rules-finding.md`
- [ ] **Security operations walkthrough** scheduled and delivered (~1 hr, script: `waf-runbook.md`)
- [ ] **Rule management and tuning training** scheduled and delivered (~1 hr, script: `waf-tuning-guide.md`)
- [ ] **osTicket DNS validation CNAME** created at Network Solutions — see below. **The ticket portal is currently plain HTTP.**

Operational follow-ups, not SOW blockers:

- [ ] Capture traffic baselines for `crm-alb-waf` and `osticket-alb-waf` after a week, replace their module-default thresholds
- [ ] osTicket ACM certificate `8c2c365f-a408-4bbf-8f6e-187a28665057` is `PENDING_VALIDATION`. **The ticket portal is currently served over plain HTTP**, so credentials submitted to it travel unencrypted. Hand this to Insight Group's DNS administrator at Network Solutions (`ns47.worldnic.com` / `ns48.worldnic.com`) — one CNAME:

  | Field | Value |
  |---|---|
  | Type | CNAME |
  | Name | `_59bfd12229b222d5a7e78deac7838a08.osticket.insightgrouppr.com.` |
  | Value | `_10c4856142562dfe22916aa3cfd5e334.jkddzztszm.acm-validations.aws.` |

  Once ACM reads `ISSUED`, Nebularis sets `enable_https = true` on the `osticket-alb` leaf — a one-line PR, ~10 minute pipeline run.
- [ ] Tag long-lived migration targets `BackupPlan = Continuous` so they land in the LZA backup vault

---

## Payment

The first 50% was issued on signing per the SOW.

The remaining 50% is contingent on the "50% upon completion" term.

**Nebularis's position, as at rev 3a.** The filtering layer — the substance of the SOW — is deployed and verified across all four internet-facing applications, and the load balancer inventory it was checked against is now known complete. What rev 2 and rev 3 found were defects in the observability and logging layers around it; both are fixed and re-verified.

We said at rev 3 that we would not invoice against a completion claim while a logging deliverable was two-thirds covered. That objection is now fully discharged:

- **Logging configured and confirmed delivering on all four Web ACLs.**
- **Monitoring verified** at 20 alarms on the corrected namespace.
- **The state-file finding confirmed not to involve a live unprotected endpoint**, and the load balancer inventory is now known complete.

**Remaining before we consider the completion claim sound:** the runbook exercise. One item, Nebularis-side, roughly 30 minutes, and not a known failure. The dashboard confirmation and the state-hygiene cleanup that were on this list are both done.

The osTicket faults described above are **not** held against this SOW. They are cutover prerequisites for a separate migration, they are not WAF defects, and they are not currently affecting anyone.

Proposal unchanged in shape:

1. **Nebularis finishes its own remaining items at no additional charge.** Listed under "Nebularis to close" above.
2. **Then invoice the remaining 50%**, with the four Insight Group items (Bot Control decision, custom-rules conversations, two training sessions) either delivered or dispositioned in writing.

If Insight Group would rather settle now against a written commitment covering step 1, that also works.

**Neither the rev 2 monitoring gap nor the rev 3 logging gap is billed as additional work.** Nor is the pipeline hardening listed under "Delivered beyond scope" — that work exists because of failures during delivery, and charging for it would be charging to fix our own.

## Sign-off

| Role | Name | Date |
|---|---|---|
| Service Provider — Nebularis Cloud LLC | _____________________ | _____________ |
| Client — Insight Group | _____________________ | _____________ |

By signing, both parties acknowledge the monitoring gap (rev 2), the logging coverage gap (rev 3 finding 1) and the orphaned state file (rev 3 finding 2) described in "Revision history", together with their remediation and current status.

---

*Reference: SOW "AWS WAF Implementation," dated March 5, 2026, between Nebularis Cloud LLC and Insight Communications Corp.*
