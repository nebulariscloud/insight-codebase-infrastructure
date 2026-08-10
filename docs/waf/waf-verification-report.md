# AWS WAF — verification report

**Prepared for Insight Group by Nebularis Cloud LLC**

| Field | Value |
|---|---|
| Project | AWS WAF Implementation |
| SOW | Dated March 5, 2026 |
| Environment | Insight Group AWS Organization — Perimeter account `713939170920`, region `us-east-2` |
| Verification rounds | Round 1: 2026-06-21 · Round 2: 2026-08-08 · Round 3: 2026-08-10 · Round 3 re-checks: 2026-08-10, post-remediation |
| Report date | 2026-08-10 |
| Technical appendix | `waf-verification-record.md` — every command and its raw output |

---

## How to read this report

Each line below is backed by an AWS API call made against the live environment, with the response recorded verbatim in the technical appendix. Nothing here is asserted from the Terraform configuration alone. Configuration says what *should* exist; these checks say what *does*.

Two of the checks below are recorded as failures found by us, and one earlier conclusion is recorded as retracted. That is deliberate. A verification report that only contains passes is not a verification report — it is a summary of the configuration. Both findings, their root causes and their remediation are included in full.

Three result values are used:

| | Meaning |
|---|---|
| **Pass** | Checked against the live environment; the observed output met a stated pass criterion. |
| **Fail** | Checked; did not meet the criterion. Root cause and remediation stated. |
| **Not verified** | Not yet checked. Explicitly listed rather than assumed. |

---

## Summary of all verifications

| # | What was verified | Date | Result |
|---|---|---|---|
| V1 | WAF log bucket exists, KMS-encrypted with a dedicated CMK, SSE-C blocked | 2026-06-21 | **Pass** |
| V2 | WAF logging attached to `ingress-alb-waf` and `scriptcase-lb-waf`, with `authorization` and `cookie` headers redacted | 2026-06-21 | **Pass** |
| V3 | Six CloudWatch alarms exist with the designed naming pattern | 2026-06-21 | **Pass (existence only)** — the accompanying "healthy" conclusion was **retracted**, see Correction 1 |
| V4 | Three severity-tiered SNS topics exist with confirmed (not pending) email subscriptions | 2026-06-21 | **Pass** |
| V3-R | The alarm metric pipeline actually publishes data — asserted on datapoint counts, not alarm state | 2026-08-08 | **Pass** |
| V5 | Every internet-facing ALB has a Web ACL attached | 2026-08-10 | **Pass** — 4 of 4 |
| V6 | CloudWatch dashboard `perimeter-waf` exists and is current | 2026-08-10 | **Pass** — console eyeball still outstanding, see "Not yet verified" |
| V7 | All four Web ACLs return real metric datapoints | 2026-08-10 | **Pass** |
| V8 | Full alarm inventory and deployed thresholds match the measured baseline | 2026-08-10 | **Pass** — 20 alarms confirmed. Correction 3 **resolved** |
| V9 | WAF log records are actually landing in S3 for every protected resource | 2026-08-10 | **Fail, then remediated — 3 of 4 confirmed.** `crm-alb-waf` now delivering. `osticket-alb-waf` awaiting one request against an idle ALB. See Correction 2 |
| V10 | Terraform state inventory contains no orphaned or duplicate state | 2026-08-10 | **Fail — but the security question is closed.** No stray load balancer exists. State cleanup outstanding. See Correction 4 |
| V11 | HTTPS enforced on every public endpoint | 2026-08-10 | **Fail** — osTicket portal is served over plain HTTP pending DNS validation |

### Where this leaves things

Of the three items outstanding when this report was first drafted:

- **V8 is resolved.** 20 alarms, as designed.
- **V9 is resolved for `crm-alb-waf`** and needs one HTTP request against an idle ALB to confirm the fourth.
- **V10's security question is answered: there is no unprotected load balancer.** What remains is state hygiene, not exposure.

Nothing on this list is now an open security exposure other than V11, the plain-HTTP ticket portal, which is blocked on a DNS record only Insight Group can create.

---

## Detail

### V1 — Log bucket exists and is properly encrypted

`aws s3api get-bucket-encryption` on `aws-waf-logs-713939170920-us-east-2`.

Bucket exists at the WAF-required `aws-waf-logs-` prefix. Encryption is `aws:kms` against a dedicated customer-managed key (`be1ae97a-dec4-4aef-8e00-ebf0965b6af4`), not the shared AWS-managed `aws/s3` key. S3 Bucket Keys enabled. Client-supplied SSE-C keys blocked.

**Pass.**

### V2 — Logging attached with credential redaction

`aws wafv2 get-logging-configuration` on both Web ACLs that existed at the time.

Both returned an active configuration pointing at the V1 bucket, with `authorization` and `cookie` redacted so credentials and session tokens never reach the log records. `ManagedByFirewallManager: false` confirms Terraform owns the configuration and no Firewall Manager policy can silently overwrite it.

**Pass** — for the two Web ACLs then in scope. Two Web ACLs created later were **not** covered; that is V9.

### V3 — Alarms exist

`aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf-` returned all six expected alarms with the designed `perimeter-waf-<webacl>-<type>` naming.

**Pass on existence.** The conclusion drawn at the time — that all six reporting `OK` proved the metric pipeline was healthy — was invalid and has been retracted. See Correction 1.

### V4 — Notification path confirmed

Three SNS topics (`perimeter-waf-high` / `-medium` / `-low`), each with the matching `insightgroup-security-{high,medium,low}@nebulariscloud.com` distribution list subscribed. Every `SubscriptionArn` is a real ARN rather than `PendingConfirmation`, meaning the AWS confirmation links were clicked and the email path works.

**Pass.**

### V3-R — Metric pipeline publishes real data

Replaces the retracted half of V3. Asserts on datapoints instead of alarm state.

- `AWS/WAFV2` namespace holds **500,210** metrics — non-zero, so the namespace resolves.
- The dimension combinations AWS emits include the `[WebACL, Region, Rule]` set the alarms target.
- `ingress-alb-waf` returned 24 datapoints and `scriptcase-lb-waf` 14 over a two-hour window, on the exact alarm dimension set.
- Every alarm reports namespace `AWS/WAFV2`.
- The two dead-man's-switch liveness alarms report `OK`. Because they alarm on *absence* of traffic, `OK` here is positive evidence that metrics are arriving — the opposite of the ambiguity in V3.

**Pass.**

### V5 — Every public ALB is behind a Web ACL

`aws wafv2 get-web-acl-for-resource` against each load balancer in the account:

```
ingress-alb      WAF=ingress-alb-waf
scriptcase-lb    WAF=scriptcase-lb-waf
crm-alb          WAF=crm-alb-waf
osticket-alb     WAF=osticket-alb-waf
```

**Pass — 4 of 4.** Worth stating plainly: this is four ALBs, not the two that existed when the SOW was signed. `crm-alb` and `osticket-alb` were built in July, were internet-facing on `0.0.0.0/0`, and had **no WAF at all** until 2026-08-10. They are protected now.

**Confirmed complete.** A full `describe-load-balancers` on 2026-08-10 returned seven load balancers in the account and no others:

| Load balancer | Scheme | Type | WAF |
|---|---|---|---|
| `ingress-alb` | internet-facing | application | `ingress-alb-waf` |
| `scriptcase-lb` | internet-facing | application | `scriptcase-lb-waf` |
| `crm-alb` | internet-facing | application | `crm-alb-waf` |
| `osticket-alb` | internet-facing | application | `osticket-alb-waf` |
| `sftp-nlb` | internet-facing | network | n/a — see below |
| `sftp-claro-nlb` | internet-facing | network | n/a |
| `wazuh-nlb` | internet-facing | network | n/a |

Every **application** load balancer has a Web ACL. The three network load balancers cannot have one: AWS WAF operates at layer 7 and supports ALBs, CloudFront, API Gateway, AppSync, Cognito and App Runner — not NLBs. Those three carry TCP services (SFTP and Wazuh agent traffic), not HTTP, so WAF is not the applicable control for them; their protection is security-group scoping.

This closes the qualification that appeared in the first draft of this report. The ALB list is now known to be complete, so "4 of 4" is unconditional.

### V6 — Dashboard exists and is current

`aws cloudwatch list-dashboards` returned `perimeter-waf`, last modified `2026-08-10T18:11:59`.

**Pass on existence and currency.** A human still needs to open it once and confirm the widgets render populated rather than blank — that is the one remaining step on SOW acceptance criterion 4, and it is listed under "Not yet verified" below rather than assumed.

### V7 — All four Web ACLs emit metrics

`get-metric-statistics` on `AllowedRequests`, per Web ACL, on the alarm dimension set:

```
ingress-alb-waf      datapoints=36
scriptcase-lb-waf    datapoints=19
crm-alb-waf          datapoints=3
osticket-alb-waf     datapoints=5
```

All four non-zero. The lower counts on `crm-alb-waf` and `osticket-alb-waf` reflect genuinely lower request volume on those applications, not a pipeline problem.

**Pass.**

### V8 — Alarm inventory and thresholds

`aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- --query 'length(MetricAlarms)'` returned **20**.

That is the designed set: five alarms per Web ACL (blocked-total, common-ruleset, known-bad-inputs, rate-limit, and the liveness dead-man's-switch) across four Web ACLs.

**Pass.** Correction 3 is resolved — the earlier six-alarm capture predated the alarm expansion. Detail in Correction 3 below.

### V9 — Log records actually landing in S3

Counting objects under each Web ACL's log prefix in `aws-waf-logs-713939170920-us-east-2`:

**First run — before remediation:**

```
ingress-alb-waf      log objects=28812
scriptcase-lb-waf    log objects=15492
crm-alb-waf          log objects=0
osticket-alb-waf     log objects=0
```

**Fail.** Two of the four protected resources had never delivered a WAF log record. Root cause and remediation in Correction 2.

**Re-run — after the remediation applied:**

```
ingress-alb-waf      log objects=28830
scriptcase-lb-waf    log objects=15502
crm-alb-waf          log objects=1
osticket-alb-waf     log objects=0
```

**3 of 4 confirmed.** `crm-alb-waf` moved from 0 to 1 — the first record landed, which is what proves the log path works end to end. Volume follows traffic from here.

`osticket-alb-waf` remains at 0. Its logging configuration is attached and identical to the one now proven working on `crm-alb-waf`; WAF only writes an object once a request has been inspected, and the osTicket ALB has simply not been hit since the change applied. One HTTP request against it settles this, and that is the last step on V9.

### V10 — Terraform state inventory

**Fail on state hygiene. The security question it raised is closed.**

An orphaned state file claiming 13 resources, including a load balancer, was found. The concern was that a second internet-facing load balancer might be running outside the WAF programme.

**It is not.** `describe-load-balancers` (see V5) returned seven load balancers and no `icc-alb`. Every application load balancer in the account has a Web ACL. Whatever that state file describes, it is not a live unprotected endpoint.

What remains is cleanup of the state object itself, so two state files can never contend over one set of resources. Detail in Correction 4.

### V11 — HTTPS on every public endpoint

**Fail.** The osTicket portal (`osticket.insightgrouppr.com`) is currently served over plain **HTTP**. Its ACM certificate `8c2c365f-a408-4bbf-8f6e-187a28665057` sits in `PENDING_VALIDATION` because the DNS validation record has not been created.

This is not a WAF defect — the Web ACL inspects the traffic either way — but it means credentials submitted to the ticket portal travel unencrypted, which is worth surfacing in the same report.

**Blocked on Insight Group's DNS administrator** at Network Solutions (`ns47.worldnic.com` / `ns48.worldnic.com`). One CNAME record:

| Field | Value |
|---|---|
| Type | CNAME |
| Name | `_59bfd12229b222d5a7e78deac7838a08.osticket.insightgrouppr.com.` |
| Value | `_10c4856142562dfe22916aa3cfd5e334.jkddzztszm.acm-validations.aws.` |

Once ACM shows `ISSUED`, Nebularis flips `enable_https = true` on the `osticket-alb` leaf. That is a one-line change and roughly a ten-minute pipeline run.

---

## Corrections to our own record

Four items where Nebularis's earlier reporting was wrong or incomplete. Each is stated with its root cause and what changed as a result.

### Correction 1 — Monitoring reported as verified when it was not (2026-06-21 → 2026-08-10)

**What we said in June:** CloudWatch monitoring and alerting delivered and verified. All eight alarms green.

**What was actually true:** the `waf-monitoring` module specified the metrics namespace as `AWS/WAFv2` (lowercase `v`). The real namespace is `AWS/WAFV2`. CloudWatch namespaces are case-sensitive, so every alarm and every dashboard widget resolved against a namespace containing zero metrics.

Because the alarms use `treat_missing_data = "notBreaching"`, an alarm watching a metric that does not exist reports `OK` — indistinguishable from a healthy one. We observed green and concluded healthy. That inference was invalid.

**Consequence:** for roughly seven weeks the WAF alarms could not fire under any circumstances and the dashboard rendered empty.

**What was not affected:** WAF inspected every request, enforced every rule, and delivered logs to S3 throughout. The protection worked. The notification about it did not.

**What went unreported during the gap.** Two genuine threshold breaches on `ingress-alb-waf`:

| Window | Blocked requests per 5 min |
|---|---|
| 2026-08-06 19:23 → 19:28 | 1958, then 1055 |
| 2026-08-07 00:23 → 00:28 | 2225, then 1081 |

Both crossed the configured threshold across two consecutive periods and should have emailed the security list. Per-rule analysis shows both were approximately 65% `AWS-IPReputation` — AWS's curated known-bad-IP list catching botnet and mass-scanner traffic, which WAF blocked correctly. **No evidence of an unhandled targeted attack during the gap.**

**Remediation, completed 2026-08-10:** namespace corrected. A dead-man's-switch alarm added per Web ACL (`AllowedRequests < 1` with `treat_missing_data = "breaching"`) so that "this alarm is watching nothing" becomes a firing condition instead of a silent pass. Verification rewritten to assert on datapoints, which is V3-R.

### Correction 2 — Two of four protected resources were never logging

**What we implied:** the SOW deliverable "Configure WAF logging to S3 and CloudWatch Logs" was complete.

**What was actually true:** it was complete for the two Web ACLs that existed in June. `crm-alb-waf` and `osticket-alb-waf`, created in July, have delivered zero log records — confirmed by V9.

**Root cause:** the `waf-logs` Terraform leaf took one variable per Web ACL (`ingress_web_acl_name`, `scriptcase_web_acl_name`) with no way to express a third or fourth. When the two new ALBs were built and given Web ACLs, there was no mechanism to enrol them. Nothing failed. The leaf planned clean and applied clean the whole time.

Structurally this is the same failure as Correction 1: a gap that produced no error signal. Both were found by asserting on observed data rather than on configuration.

**We also mischaracterised the fix internally as an optional refactor.** It is not optional — it is a required part of the logging deliverable. Recording that as our error.

**Remediation — applied 2026-08-10.** PR **#69** replaced the fixed pair of variables with a `web_acl_names` list covering all four. The plan was create-only, as predicted: `2 to add, 0 to change, 0 to destroy`, with the two working logging configurations absent from the plan entirely. Merged and applied without incident.

**Re-verified:** `crm-alb-waf` moved from 0 log objects to 1, confirming the log path works end to end for a newly enrolled Web ACL. `osticket-alb-waf` is attached and configured identically but has received no requests since the change, so it has nothing to write yet. One HTTP request against that ALB closes the last quarter of this check.

**Note on the "and CloudWatch Logs" wording.** The SOW says S3 *and* CloudWatch Logs. Only S3 is used, and that is a deliberate design decision (D2 in `waf-design-decisions.md`), not part of this correction: CloudWatch Logs ingestion is by far the most expensive of the three destinations at per-request WAF volume, and the alternative Firehose path is blocked by an existing organizational SCP. S3 keeps the records queryable via Athena at a fraction of the cost. If Insight Group wants the CloudWatch Logs path specifically, it is available as a scoped change with a cost estimate attached.

### Correction 3 — Alarm inventory not confirmed at current state — **RESOLVED**

The alarm set was expanded on 2026-08-10 from 6 alarms to an expected 20 — five per Web ACL (blocked-total, common-ruleset, known-bad-inputs, rate-limit, liveness) across four Web ACLs — with per-Web-ACL thresholds derived from the measured baseline in `waf-traffic-baseline.md`.

Our internal notes recorded that 20-alarm inventory as verified. A later capture, however, showed only the original six alarm names. Rather than pick whichever record we preferred, we recorded V8 as **not verified** and asked for a re-run.

**Result: 20 alarms.** The six-alarm capture predated the expansion; it was a stale reading, not evidence of a failed apply. V8 is a pass.

**Kept in this report despite being resolved**, because the handling is the point. The June failure (Correction 1) was not the namespace typo — it was reporting monitoring as verified on the strength of a signal that did not support the claim. Recording a discrepancy as unverified and spending one command to settle it is the behaviour that failure was supposed to produce. Deleting the correction once it came back clean would remove the evidence that it happened.

### Correction 4 — Orphaned Terraform state file

`crm-alb` was renamed from `icc-alb` in an earlier PR. The old state file was never cleaned up:

```
s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate
serial 2 · lineage 4d7fafc8-9e41-1cdf-d9e3-14c241ab8901 · last modified 2026-07-17
13 resources, including aws_lb.this, aws_security_group.alb,
aws_acm_certificate.icc, two target groups, two listener rules
```

Thirteen resources are claimed by a state file no live Terraform leaf points at. The question that mattered was whether one of them — the load balancer — was still running.

**Answered: it is not.** `describe-load-balancers` on 2026-08-10 returned seven load balancers in the account, listed in full under V5. There is no `icc-alb`, and every application load balancer present has a Web ACL.

**No unprotected internet-facing endpoint exists.** That was the material risk in this finding and it is closed.

What is left is state hygiene, one of two variants, and the remediation is the same either way:

| | Scenario | Status |
|---|---|---|
| (a) | The state describes the same resources `crm-alb` now manages | Possible. Dual-management hazard: two state files claiming one set of resources, where a future apply against either could contend with the other. |
| (b) | A separate `icc-alb` load balancer is still running | **Ruled out.** |
| (c) | The resources are already gone; the state is purely stale | Possible. |

Distinguishing (a) from (c) means reading the `aws_lb` ARN out of the orphaned state and comparing it to `crm-alb`'s. Worth doing before deletion, because it also reveals whether the `aws_security_group` and `aws_acm_certificate` in that state are shared with `crm-alb` or are unmanaged leftovers. Neither carries cost, but an unmanaged security group is worth knowing about.

Remediation in both cases: back up the state object, then remove it and its DynamoDB lock digest. Deleting a state object is irreversible, so the backup comes first. Step 7 of `waf-finish-checklist.md`.

**Why this belongs in a WAF report.** V5 concluded "4 of 4 ALBs protected," and that conclusion is only as good as the list of ALBs it was checked against. Chasing this finding is what produced the full account-wide load balancer enumeration, which is what makes V5 unconditional rather than a statement about the ALBs we happened to know of.

---

## What the corrections have in common

Both Correction 1 and Correction 2 were silent. No apply failed, no plan went red, no alarm fired. In both cases the Terraform configuration was internally consistent and simply did not describe reality.

That produced three durable changes to how the estate is verified, all now in place:

1. **Liveness alarms.** Each Web ACL carries an alarm that fires on the *absence* of traffic metrics. A monitoring stack that has stopped working now says so.
2. **Verification asserts on data, not configuration or state.** Datapoint counts and object counts, not "the resource exists" or "the alarm is green".
3. **Coverage cross-checks.** `waf-finish-checklist.md` now enumerates protected resources from AWS and compares against the Terraform inputs, so a resource created without logging or without a Web ACL is caught rather than inferred.

---

## Not yet verified

Listed explicitly. These are gaps in verification, not known failures.

| Item | Why not verified | How to close |
|---|---|---|
| `osticket-alb-waf` log delivery | The ALB has had no traffic since the logging change applied, so WAF has nothing to write | One HTTP request against it, then re-run V9 — checklist step 6a |
| Dashboard widgets render populated | Requires a human to look at it | Open the `perimeter-waf` dashboard in the console — checklist step 1 |
| Whether the orphaned state duplicates `crm-alb` or is fully stale | Not needed to answer the security question, which is closed | Read the `aws_lb` ARN out of the state and compare — checklist step 7 |
| Incident response runbook exercised end to end | The runbook is written but has never been run | Block/unblock exercise, ~30 min — checklist step 2 |
| `crm-alb-waf` / `osticket-alb-waf` traffic baselines | Need a week of data; they currently run on module-default thresholds | Re-run the baseline capture after a week |
| Bot Control efficacy | Not deployed — pending an Insight Group cost decision | See `waf-sow-closeout.md`, open item 1 |

---

## Bottom line

The filtering layer is verified working. All four internet-facing applications are inspected by AWS WAF with the OWASP-aligned managed rule groups and per-IP rate limiting active, and no legitimate traffic has been observed blocked.

The observability layer around it was where the defects were, and both were the same shape: something silently uncovered, reporting green. Both are now fixed and re-verified — Correction 1 by the namespace fix and the liveness alarms, Correction 2 by PR #69, merged and applied on 2026-08-10.

**No open security exposure remains in the WAF layer.** The state-file finding turned out not to involve a live endpoint. The one exposure still on the list is unrelated to WAF: the osTicket portal is served over plain HTTP, and that is blocked on a DNS record only Insight Group can create.

What is genuinely outstanding is small: one HTTP request to confirm the fourth Web ACL's log delivery, one look at the dashboard, one runbook exercise, and cleanup of a stale state object. Nebularis's recommendation is to treat those as a single short session, and to treat Bot Control, the custom-rules review and the two training sessions as the actual remaining decisions. Detail and sign-off in `waf-sow-closeout.md`.

---

## Where the evidence lives

| Document | Contents |
|---|---|
| `waf-verification-record.md` | Every command run and its raw output, including the retraction of V3 |
| `waf-traffic-baseline.md` | Measured traffic volumes and how each alarm threshold was derived from them |
| `waf-design-decisions.md` | 14 decision records covering why each choice was made and what was rejected |
| `waf-sow-closeout.md` | SOW acceptance criteria, deliverable status, open items, sign-off block |
| `waf-finish-checklist.md` | The open items above as copy-paste commands |
| `waf-architecture.md` | What is deployed and how it is wired |
| `waf-runbook.md` | Incident response procedure |
| `waf-tuning-guide.md` | How to add, promote and roll back rules |
