# WAF — finish checklist

Everything still required to close the SOW, in order, with the exact commands.

Work top to bottom. Steps marked **[HUMAN]** are conversations or sessions with no command to run. Everything else is copy-paste.

**Status as of 2026-08-10.** The filtering layer is deployed and verified on all four internet-facing applications. Remaining:

| | Item | Who |
|---|---|---|
| ~~Step 1~~ | ~~Dashboard visual confirmation~~ | **DONE 2026-08-10** |
| Step 2 | Runbook exercise — **the only WAF item left on our side** | Nebularis |
| Step 3 | Bot Control decision | **Insight Group** |
| Step 4 | Custom rules review | **Insight Group** (4 owner conversations) |
| Step 5 | Two training sessions | Both |
| ~~Step 6~~ | ~~Log delivery + alarm inventory~~ | **DONE 2026-08-10** |
| ~~Step 7~~ | ~~Orphaned `icc-alb` state~~ | **DONE 2026-08-10** |
| Step 8 | osTicket HTTPS + **8d, two latent faults**. Cutover prerequisite, not urgent | Insight Group's DNS admin, then Nebularis |
| Step 9 | crm / osticket baselines | Nebularis, after a week of data |

Steps 6 and 7 were added after a wider verification round on 2026-08-10 found that two of the four Web ACLs had never delivered a log record, and that an orphaned state file claims 13 resources. Detail in `waf-verification-report.md`.

**Progress as of 2026-08-10 — everything with an unknown answer is now settled:**

- **Step 6 complete.** PR **#69** merged and applied. All four Web ACLs delivering log records: 28830 / 15502 / 1 / 4. The SOW logging deliverable covers every protected resource.
- **Alarm inventory: 20.** The earlier six-alarm reading was stale, from before #62's apply.
- **Account-wide load balancer enumeration: 7 LBs, 4 ALBs, all four with a Web ACL, no `icc-alb`.** The orphaned state does not correspond to a live unprotected endpoint. Step 7 drops from "possible security exposure" to state cleanup.
- **PRs #58, #69 and #70 all merged**; nothing open.
- **Step 1 DONE.** Dashboard exists, body references only `AWS/WAFV2`, all four Web ACLs returning datapoints, and a human confirmed the widgets render populated. **SOW acceptance criterion 4 fully met.**
- **Step 7 DONE.** Resolved to scenario (c) — the `icc-alb` load balancer was already destroyed, and the destroy had been partial. `icc-alb-sg` (`sg-076c916a807936cee`) deleted, state object and lock digest removed, backup taken. Certificate inventory clean: four certs, all accounted for.

> ### osTicket has two latent faults — step 8d. **Cutover prerequisite, not an outage.**
>
> Not a WAF defect. And not urgent: `osticket.insightgrouppr.com` has not been pointed at this load balancer, and the validation CNAME is deliberately deferred to cutover. The help desk is still on the pre-migration host.
>
> - The target group is **unhealthy** (`Target.ResponseCodeMismatch`); the load balancer has been failing open, which is why nobody noticed.
> - osTicket **301s to `https://osticket.insightgrouppr.com/`**, and there is **no 443 listener** because `enable_https = false`. A browser following that redirect hits a closed port.
>
> Both are harmless today and both break the help desk the moment DNS moves. **Fix them before the cutover window, not during it** — steps 1–3 of the cutover ordering in 8d are reversible and do not touch the live help desk.
>
> Consequence for the SOW record: `osticket-alb-waf` is deployed, attached, logging and alarming, but until DNS moves it is inspecting test traffic rather than real users. Stated plainly in `waf-sow-closeout.md`.

**Priority order: step 2 is the only thing left on the Nebularis side** — the ~30 minute runbook exercise. Steps 3–5 need Insight Group. Step 8d belongs to the osTicket migration checklist.

---

## Account cheat sheet

Every command block below asserts the account before doing anything. Get this wrong and the output looks like a broken system — it cost hours on 2026-08-10.

| Account | ID | Holds |
|---|---|---|
| **Perimeter** | `713939170920` | All Web ACLs, all 4 public ALBs, WAF logs bucket, alarms, dashboard, SNS |
| Production | `395516496764` | shared-prod VPC, EC2, RDS. **No WAF.** |
| SharedServices | `547368325532` | Terraform state bucket + lock table |

---

## Step 0 — Merge the open PRs

**All merged as of 2026-08-10. Nothing open.**

- [x] **PR #69** — `waf-logs`: enrol `crm-alb-waf` and `osticket-alb-waf` in logging. Plan read `2 to add, 0 to change, 0 to destroy`, as predicted; apply clean.
- [x] **PR #70** — verification report, closeout rev 3, checklist steps 6 and 7.
- [x] **PR #58** — cti-v7 operations docs.

Earlier in the sequence, listed so the numbering isn't confusing: **#67** (closeout
rev 2), **#68** (training material, custom-rules template).

Verified on `main` rather than trusted from the merge — #67 once merged at a stale
head and silently dropped a file:

```bash
git fetch insight-remote main
git ls-tree --name-only insight-remote/main docs/waf/   # expect 12 files
```

---

## Step 1 — Confirm the dashboard populates — **DONE 2026-08-10**

> **COMPLETE.** All three checks passed: the dashboard exists and post-dates the
> namespace fix, its widget definitions reference only `AWS/WAFV2`, and a human
> confirmed in the console that the widgets render populated with real data and
> graphs. **SOW acceptance criterion 4 is fully met.**

Retained below as the standing procedure — re-run it after any change to the
`waf-monitoring` module or leaf.

### What and where

A **CloudWatch dashboard** named **`perimeter-waf`**, in the **Perimeter** account
`713939170920`, region **us-east-2**. It is created by
`terraform/live/perimeter/waf-monitoring` via the `waf-monitoring` module — not by
LZA, and not something you have to build.

Console path: **CloudWatch → Dashboards → `perimeter-waf`**, or direct:

```
https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/perimeter-waf
```

Make sure the console is in the Perimeter account and us-east-2 before judging it
empty. Production `395516496764` has no WAF, so from there the dashboard either
does not appear or renders blank — the exact ambiguity that cost hours on
2026-08-10.

### What it should show

Four rows, one per Web ACL — `ingress-alb-waf`, `scriptcase-lb-waf`,
`crm-alb-waf`, `osticket-alb-waf` — plus a rollup row across all four. Each Web
ACL row has three widgets:

| Widget | Expect |
|---|---|
| Traffic: allowed / blocked / counted | A line with real values. `ingress` and `scriptcase` are busiest; `crm` and `osticket` will be sparse but non-zero |
| Blocks broken down by rule | `AWS-IPReputation` should dominate on `ingress` — roughly 65% of its blocks are scanner noise |
| Rate-limit single-value panel | **`0` is the correct answer.** The rate-based rule has never triggered |

**The failure mode you are looking for is blank widgets or "No data available"**,
which is what the whole estate showed from June until the namespace fix. Values —
including zeros in the rate-limit panels — mean it works.

### Verify from the CLI too

Widgets can look empty for boring reasons (time range set to 1 hour on an idle
ALB). These commands confirm the underlying data independently:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

# Dashboard exists?
aws cloudwatch list-dashboards --region us-east-2 \
  --query 'DashboardEntries[?DashboardName==`perimeter-waf`].[DashboardName,LastModified]' \
  --output table

# Are the widgets pointed at the corrected namespace? Must print AWS/WAFV2
# (capital V) and nothing else. Any AWS/WAFv2 here is the June defect returning.
aws cloudwatch get-dashboard --dashboard-name perimeter-waf --region us-east-2 \
  --query 'DashboardBody' --output text \
  | grep -o 'AWS/WAF[Vv]2' | sort -u

# Every Web ACL returning datapoints? (all four should be > 0)
for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  n=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/WAFV2 --metric-name AllowedRequests \
    --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=ALL \
    --start-time "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --region us-east-2 \
    --query 'length(Datapoints)' --output text)
  printf "%-20s datapoints(2h)=%s\n" "$acl" "$n"
done
```

> `date -u -d '2 hours ago'` is GNU. On macOS use `date -u -v-2H`.

- [x] Dashboard `perimeter-waf` exists — `LastModified 2026-08-10T18:11:59`
- [x] `get-dashboard` prints **only** `AWS/WAFV2` — confirmed 2026-08-10, single line of output, no lowercase-`v` variant anywhere in the body
- [x] All four Web ACLs report datapoints > 0 — 36 / 19 / 3 / 5
- [x] Opened the dashboard in the console and the widgets show values, not "No data available" — **confirmed 2026-08-10, populated with real data and graphs**

**Step 1 complete. SOW acceptance criterion 4 is fully met.**

`crm-alb-waf` and `osticket-alb-waf` may show 0 briefly if their ALBs are idle — widen the dashboard time range to 3 hours, or re-run after some traffic.

Set the dashboard time range to **3 hours** on first look. The default is often 1 hour, which on the quieter ALBs can be genuinely empty and read as broken.

---

## Step 2 — Test the incident response runbook

SOW acceptance criterion says "tested and validated". ~30 minutes. Uses `osticket-alb` because it's Terraform-managed, so the whole flow goes through the normal PR path.

### 2a. Get your public IP

```bash
curl -s https://checkip.amazonaws.com
```

### 2b. Branch and add the deny rule

```bash
cd /path/to/lza-universal-config-hub-and-spoke
git fetch insight-remote main
git checkout -b test/waf-runbook-deny-exercise insight-remote/main
```

Edit `terraform/live/perimeter/osticket-alb/main.tf`. In the `module "waf"` block, add `deny_ip_cidrs`:

```hcl
module "waf" {
  source = "../../../modules/waf-managed"

  name  = "${var.stack_name}-waf"
  scope = "REGIONAL"

  rate_limit = var.waf_rate_limit

  # TEMPORARY — runbook validation exercise, remove in the follow-up PR.
  # Replace with the IP from `curl https://checkip.amazonaws.com`.
  deny_ip_cidrs = ["YOUR.IP.HERE/32"]

  tags = {
    Role = "osticket-alb-waf"
  }
}
```

```bash
terraform fmt -check -recursive terraform/ && echo "fmt clean"
git add terraform/live/perimeter/osticket-alb/main.tf
git commit -m "test(waf): runbook validation — temporarily deny one source IP

Exercises the documented incident response path end to end: PR flow,
destroy guard, apply, WAF block, log delivery, CloudWatch metric.
Reverted immediately in the follow-up PR.

Satisfies the SOW acceptance criterion that the runbook be tested and
validated, not merely written."
git push -u insight-remote test/waf-runbook-deny-exercise

gh pr create --base main --head test/waf-runbook-deny-exercise \
  --repo nebulariscloud/insight-codebase-infrastructure \
  --title "test(waf): runbook validation — temporarily deny one source IP" \
  --body "Runbook validation exercise per the SOW acceptance criterion. Adds a single /32 to osticket-alb-waf's deny list, verifies the block reaches the logs and metrics, then reverts. Expected plan: 1 IPSet created, Web ACL updated in place. No destroys."
```

- [ ] Plan shows: 1 `aws_wafv2_ip_set` created, Web ACL updated in place, **0 destroyed**
- [ ] Merge and let it apply

### 2c. Verify the block

```bash
# From the denied IP — expect 403
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://<osticket-alb-dns-name>/
```

Get the ALB DNS name with:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT"; exit 1; }
aws elbv2 describe-load-balancers --names osticket-alb --region us-east-2 \
  --query 'LoadBalancers[0].DNSName' --output text
```

### 2d. Confirm it reached the metric and the logs

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT"; exit 1; }

# Metric — the DenyList rule should have a non-zero Sum
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value=osticket-alb-waf Name=Region,Value=us-east-2 Name=Rule,Value=DenyList \
  --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum --region us-east-2 --output table

# Sampled requests — should show your IP with action BLOCK
ARN=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
  --query "WebACLs[?Name=='osticket-alb-waf'].ARN | [0]" --output text)
aws wafv2 get-sampled-requests --web-acl-arn "$ARN" \
  --rule-metric-name DenyList --scope REGIONAL --region us-east-2 --max-items 5 \
  --time-window StartTime=$(date -u -d '20 minutes ago' +%s),EndTime=$(date -u +%s) \
  --query 'SampledRequests[].[Timestamp,Action,Request.ClientIP,Request.URI]' --output table
```

Logs take ~5 minutes to land in S3:

```bash
aws s3 ls s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/osticket-alb-waf/ \
  --recursive --region us-east-2 | tail -3
```

- [ ] `curl` from the denied IP returned 403
- [ ] `DenyList` metric non-zero
- [ ] `get-sampled-requests` shows the IP with `BLOCK`
- [ ] Log objects present in S3

### 2e. Revert

```bash
git fetch insight-remote main
git checkout -b test/waf-runbook-deny-revert insight-remote/main
```

Remove the `deny_ip_cidrs` line from `terraform/live/perimeter/osticket-alb/main.tf`.

```bash
terraform fmt -check -recursive terraform/ && echo "fmt clean"
git add terraform/live/perimeter/osticket-alb/main.tf
git commit -m "test(waf): revert the runbook validation deny rule

Exercise complete. Removes the temporary /32 deny and its IPSet.

ALLOW-DESTROY: terraform/live/perimeter/osticket-alb"
git push -u insight-remote test/waf-runbook-deny-revert

gh pr create --base main --head test/waf-runbook-deny-revert \
  --repo nebulariscloud/insight-codebase-infrastructure \
  --title "test(waf): revert the runbook validation deny rule" \
  --body "Reverts the temporary deny rule. Expected plan: 1 IPSet destroyed, Web ACL updated in place.

The destroy guard will flag the IPSet removal — that is correct and expected. Authorised in the commit message.

ALLOW-DESTROY: terraform/live/perimeter/osticket-alb"
```

- [ ] Merged, applied, IPSet gone
- [ ] Confirm access restored: `curl` returns something other than 403

### 2f. Record it

Append to the bottom of `docs/waf/waf-runbook.md`:

```markdown
## Validation record

- **2026-__-__** — Runbook exercised end to end per the SOW acceptance criterion.
  Denied a single controlled source IP on `osticket-alb-waf` via the normal PR
  flow, confirmed HTTP 403 from that source, a non-zero `DenyList` metric, the
  request visible in `get-sampled-requests` with action `BLOCK`, and log objects
  delivered to `aws-waf-logs-713939170920-us-east-2`. Reverted via a second PR;
  the destroy guard correctly flagged the IPSet removal and was authorised.
  Elapsed: __ minutes. Run by: ____________.
```

- [ ] Recorded and committed

---

## Step 3 — Bot Control decision **[HUMAN]**

The only substantive technical gap. Named in the SOW objectives, success metrics, deliverables **and** acceptance criteria, so it cannot be silently skipped.

**Cost:** ~$10 per Web ACL per month plus per-request inspection fees. Four Web ACLs ≈ $40/month before volume.

**Risk:** `SignalAutomatedBrowser` and `CategoryHttpLibrary` commonly fire on legitimate synthetic monitoring and API clients using `requests` / `curl`. The CRM ALB fronts exactly that.

- [ ] Insight Group decides: **deploy** (Step 3a) or **waive** (Step 3b)

### 3a. If deploying — start with Scriptcase in Count mode

Edit `terraform/live/perimeter/scriptcase-lb/…` — note `scriptcase-lb-waf` is currently **CloudFormation-managed** (`aws-accelerator-config/custom-stacks/scriptcase-lb.yaml`), so this requires either an LZA pipeline change or migrating that Web ACL to Terraform first.

**Simpler starting point: use `osticket-alb`**, which is already Terraform-managed. In its `module "waf"` block:

```hcl
  enable_bot_control           = true
  bot_control_inspection_level = "COMMON"

  # Start everything in Count so nothing is blocked while baselining.
  bot_control_overrides_to_count = [
    "CategoryHttpLibrary",
    "SignalAutomatedBrowser",
    "SignalNonBrowserUserAgent",
    "CategoryAdvertising",
    "CategoryArchiver",
    "CategoryContentFetcher",
    "CategoryEmailClient",
    "CategoryLinkChecker",
    "CategoryMiscellaneous",
    "CategoryMonitoring",
    "CategoryScrapingFramework",
    "CategorySearchEngine",
    "CategorySecurity",
    "CategorySeo",
    "CategorySocialMedia",
    "CategoryAI",
  ]
```

PR it, apply, then wait **7 days** and review what Count caught:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT"; exit 1; }

aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 --metric-name CountedRequests \
  --dimensions Name=WebACL,Value=osticket-alb-waf Name=Region,Value=us-east-2 Name=Rule,Value=AWS-BotControl \
  --start-time "$(date -u -d '4 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Sum --region us-east-2 \
  --query 'sort_by(Datapoints,&Sum)[-5:].[Timestamp,Sum]' --output table
```

Then remove from `bot_control_overrides_to_count` only the sub-rules that caught nothing legitimate, and repeat. Full procedure in `waf-tuning-guide.md`.

- [ ] Deployed in Count on one Web ACL
- [ ] 7 days observed
- [ ] Promoted to Block
- [ ] Extended to remaining Web ACLs

### 3b. If waiving

- [ ] Written SOW amendment recording the waiver and the reason
- [ ] Note it in `docs/waf/waf-sow-closeout.md` under open item 1

---

## Step 4 — Custom rules review **[HUMAN]**

The deliverable is worded as an artefact and there are currently none. That may be correct, but the finding has to be recorded either way.

Ask the owners of Wazuh, Scriptcase, the CRM API and osTicket:

1. Any endpoint seeing credential stuffing or brute force?
2. Any path being scraped?
3. Any API consumer that should have its own rate limit?
4. Any known-bad user-agent or header pattern?

**If rules are needed**, the module already supports them:

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

**If none are needed**, add to `docs/waf/waf-architecture.md`:

```markdown
## Custom rules

Reviewed 2026-__-__ with the owners of Wazuh, Scriptcase, the CRM API and
osTicket. No application-specific abuse patterns were identified beyond what the
AWS managed rule groups already cover, and four days of measured traffic showed
none. No custom rules are deployed. The `waf-managed` module supports them via
`custom_rules` if that changes.
```

- [ ] Owners consulted
- [ ] Rules added, or finding recorded

---

## Step 5 — Training sessions **[HUMAN]**

~1 hour each. The written guides are the scripts.

### 5a. Security operations walkthrough — script: `waf-runbook.md`

Cover: what each of the 20 alarms means and which are actionable; how to read the dashboard; the triage table; how to block or allow an IP through the PR flow; why `AWS-IPReputation` is deliberately not alarmed on; when to escalate.

- [ ] Delivered — date: ________ attendees: ________

### 5b. Rule management and tuning — script: `waf-tuning-guide.md`

Cover: rule evaluation order; the Count-then-promote discipline; the false-positive workflow using `get-sampled-requests`; adding a per-path rate limit; how thresholds were derived and when to revisit.

- [ ] Delivered — date: ________ attendees: ________

---

## Step 6 — Verify log delivery for all four Web ACLs, and confirm the alarm inventory

Both of these close findings from closeout rev 3. Neither is optional.

### 6a. Log delivery — every Web ACL must be above zero

Verified 2026-08-10: **two of four were at zero.** `crm-alb-waf` and
`osticket-alb-waf` had never delivered a WAF log record, because the `waf-logs`
leaf hard-coded two Web ACL variables with no way to express a third. **PR #69**
fixes that. Merge it, let CI apply, wait ~5 minutes, then run this.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  arn=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
    --query "WebACLs[?Name=='$acl'].ARN | [0]" --output text)
  dest=$(aws wafv2 get-logging-configuration --resource-arn "$arn" --region us-east-2 \
    --query 'LoggingConfiguration.LogDestinationConfigs[0]' --output text 2>/dev/null || echo NONE)
  n=$(aws s3 ls \
    "s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/$acl/" \
    --recursive 2>/dev/null | wc -l | tr -d ' ')
  printf "%-20s dest=%-50s objects=%s\n" "$acl" "$dest" "$n"
done
```

- [x] **PR #69 merged and applied — done 2026-08-10.** Plan read `2 to add, 0 to change, 0 to destroy`, as predicted. Apply clean.
- [x] All four report `dest = arn:aws:s3:::aws-waf-logs-713939170920-us-east-2`
- [x] `crm-alb-waf` above zero — moved 0 → 1
- [x] `osticket-alb-waf` above zero — **4 objects after 6c**

Result after apply:

```
ingress-alb-waf      objects=28830
scriptcase-lb-waf    objects=15502
crm-alb-waf          objects=1     <- was 0
osticket-alb-waf     objects=4     <- was 0, after the forced request in 6c
```

`crm-alb-waf` going 0 → 1 is the signal that matters: it proves the logging
config, bucket policy and KMS grant all work for a newly enrolled Web ACL.

**Step 6 is complete. The SOW logging deliverable now covers all four protected
resources.**

### 6c. Force one request through osTicket — **DONE 2026-08-10**

`osticket-alb-waf` was attached and configured identically to `crm-alb-waf`, but
WAF writes an object only after inspecting a request and that ALB had had none
since the apply. Confirmed rather than assumed:

```bash
# Plain HTTP: the cert is still PENDING_VALIDATION (step 8).
curl -sS -o /dev/null -w 'http status: %{http_code}\n' \
  http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/

sleep 360   # WAF batches to S3 in ~5-minute windows

aws s3 ls \
  "s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/osticket-alb-waf/" \
  --recursive | wc -l
```

Result:

```
http status: 500
4
```

- [x] Count is 1 or more — **4**

Any HTTP status proves the point. 200, 302, 404 or 500 all mean WAF inspected the
request and wrote a record, which is the only thing this step tests.

V9 is recorded as Pass in `waf-verification-record.md` and
`waf-verification-report.md`.

**The `500` is a separate matter — see step 8d.** It is not a WAF result and does
not affect this step, but it should not be ignored.

### 6b. Alarm inventory — **DONE 2026-08-10: 20 confirmed**

```
$ aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
    --region us-east-2 --query 'length(MetricAlarms)' --output text
20
```

PR #62's apply landed correctly. The six-alarm capture that raised the question
was a stale reading from before the expansion. V8 is a pass.

- [x] Count is **20**

The namespace / threshold columns are worth eyeballing on the same command output
when you open the dashboard for step 1, since both come from one call:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

echo "alarm count: $(aws cloudwatch describe-alarms \
  --alarm-name-prefix perimeter-waf- --region us-east-2 \
  --query 'length(MetricAlarms)' --output text)   (expected 20)"

aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
  --region us-east-2 \
  --query 'sort_by(MetricAlarms,&AlarmName)[].[AlarmName,StateValue,Namespace,Threshold]' \
  --output table
```

- [ ] Every `Namespace` reads `AWS/WAFV2` — capital `V`, this is the June defect
- [ ] All four `*-no-metrics` liveness alarms present and `OK`. `OK` here is the meaningful signal: they alarm on *absence*, so `OK` positively confirms metrics are arriving
- [ ] Thresholds match the baseline: ingress 4000 / 700 / 600 / 100 · scriptcase 600 / 400 / 250 / 100 · crm + osticket on module defaults 600 / 400 / 300 / 100

If a future run returns **6**, the `waf-monitoring` leaf did not apply. Its
original apply was cancelled once and re-driven by dispatch; re-drive it again:

```bash
gh workflow run terraform.yml \
  --repo nebulariscloud/insight-codebase-infrastructure \
  -f leaf=terraform/live/perimeter/waf-monitoring \
  -f apply=true
```

- [ ] If re-driven: re-run the inventory command above and confirm 20

V8 is already recorded as Pass in `waf-verification-record.md` and
`waf-verification-report.md`.

---

## Step 7 — Clean up the orphaned `icc-alb` state — **DONE 2026-08-10**

> **COMPLETE.** Resolved to scenario (c): the `icc-alb` load balancer was already
> destroyed. The destroy had been partial, leaving `icc-alb-sg`
> (`sg-076c916a807936cee`) behind. Both the security group and the state object
> are now removed:
>
> ```
> $ aws ec2 delete-security-group --group-id sg-076c916a807936cee
> {"Return": true, "GroupId": "sg-076c916a807936cee"}
>
> $ aws s3 cp s3://.../live/perimeter/icc-alb/terraform.tfstate ./icc-alb-orphan-state-backup.json
> $ aws s3 rm s3://.../live/perimeter/icc-alb/terraform.tfstate
> $ aws dynamodb delete-item --table-name lza-terraform-locks \
>     --key '{"LockID":{"S":".../live/perimeter/icc-alb/terraform.tfstate-md5"}}'
> ```
>
> `delete-security-group` returning `Return: true` rather than
> `DependencyViolation` is the authoritative confirmation that nothing referenced
> it — better than any query, because AWS checks every reference type including
> ones a targeted `describe` call would miss.
>
> Certificate inventory afterwards shows exactly four, all accounted for, no
> `icc-alb` leftover:
>
> | Domain | Status | InUse |
> |---|---|---|
> | `wazuh.insightgrouppr.com` | ISSUED | true |
> | `sc.insightgrouppr.com` | ISSUED | true |
> | `crm.insightgrouppr.com` | ISSUED | true |
> | `osticket.insightgrouppr.com` | PENDING_VALIDATION | false |
>
> The backup is at `./icc-alb-orphan-state-backup.json` on the operator's
> machine. **It is the only remaining record of what `icc-alb` consisted of** —
> worth parking somewhere durable rather than leaving in a home directory.

### Caveat on the reference checks, for next time

The `describe-security-groups` query below only searches **one account**. Security
groups can be referenced across accounts over a peered VPC, or over a same-region
Transit Gateway with security group referencing enabled, and a single-account query
would never see it.

It did not matter here — the `alb` module writes CIDR-only rules (`cidr_ipv4`,
never `referenced_security_group_id`), and the only SG-to-SG references anywhere in
`terraform/` are to `var.eice_security_group_id`, the EC2 Instance Connect Endpoint
group in Production. Nothing references a perimeter ALB security group.

**But do not rely on the query for that conclusion.** Attempt the delete and let
AWS answer: `delete-security-group` is non-destructive on failure, returning
`DependencyViolation` and changing nothing. That is the check that cannot be
incomplete.

---

### Original investigation, retained for the record

> **The security question here is already answered: there is no stray load
> balancer.** An account-wide enumeration on 2026-08-10 returned seven load
> balancers — `sftp-nlb`, `sftp-claro-nlb`, `wazuh-nlb` (all network, WAF does not
> apply) and the four ALBs, every one of which has a Web ACL. No `icc-alb`.
>
> That also lifted the "all four *known* ALBs" qualification on acceptance
> criterion 1. The ALB inventory is now known complete.
>
> What is left below is **state hygiene, not exposure.** Do it, but it no longer
> gates anything.

`crm-alb` was renamed from `icc-alb` in PR #45. The old state object was never
removed and still claims **13 resources**:

```
s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate
serial 2 · lineage 4d7fafc8-9e41-1cdf-d9e3-14c241ab8901 · modified 2026-07-17

aws_lb.this · aws_security_group.alb · aws_acm_certificate.icc
aws_lb_target_group.{this,dev} · aws_lb_target_group_attachment.{prod,dev}
aws_lb_listener.http · aws_lb_listener_rule.{prod_host,dev_host}
aws_vpc_security_group_{ingress_rule.http,ingress_rule.https,egress_rule.to_targets}
```

No leaf on `main` points at it. Three scenarios:

| | Scenario | Status |
|---|---|---|
| **(a)** | Same resources `crm-alb` now manages | **RULED OUT 2026-08-10** — the state's ALB DNS name is `icc-alb-396237492...`, not `crm-alb-142110994...`. Different load balancer; `crm-alb` was rebuilt, not renamed in place. |
| **(b)** | A separate `icc-alb` ALB is still running | **RULED OUT 2026-08-10** — no `icc-alb` in the account. |
| **(c)** | Resources already gone, state purely stale | **CONFIRMED** — but the destroy was partial. `icc-alb-sg` (`sg-076c916a807936cee`) survives, unmanaged. |

### 7a. Which one is it — (a) or (c)

Already done, for the record:

```
$ aws elbv2 describe-load-balancers --region us-east-2 \
    --query 'LoadBalancers[].[LoadBalancerName,Scheme,Type,DNSName]' --output table

sftp-nlb         internet-facing  network      sftp-nlb-34a55ff7c8bc1fe1.elb...
sftp-claro-nlb   internet-facing  network      sftp-claro-nlb-355d444eae8c5f3a.elb...
wazuh-nlb        internet-facing  network      wazuh-nlb-c809fdc006300e6f.elb...
ingress-alb      internet-facing  application  ingress-alb-122459471.us-east-2.elb...
scriptcase-lb    internet-facing  application  scriptcase-lb-1093571739.us-east-2.elb...
crm-alb          internet-facing  application  crm-alb-142110994.us-east-2.elb...
osticket-alb     internet-facing  application  osticket-alb-343594101.us-east-2.elb...
```

- [x] Enumerated — no `icc-alb`, scenario (b) ruled out

To tell (a) from (c), with credentials that can read the SharedServices state bucket:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "547368325532" ] && { echo "WRONG ACCOUNT ($ACCT) — need SharedServices"; exit 1; }

aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate - \
  --region us-east-2 \
  | jq -r '.resources[] | select(.type=="aws_lb") | .instances[].attributes | "\(.name)  \(.arn)  \(.dns_name)"'
```

**Measured 2026-08-10:**

```
icc-alb  icc-alb-396237492.us-east-2.elb.amazonaws.com
```

- [x] Recorded the ALB name / DNS name from the orphaned state
- [x] Compared against the live list

**This is scenario (c), with a wrinkle.** `icc-alb-396237492...` is a *different*
DNS name from `crm-alb-142110994...`, so this was never the same load balancer
under a new name — `crm-alb` was rebuilt rather than renamed in place. And
`describe-load-balancers` shows no `icc-alb`, so that ALB is gone.

**But not everything in the state is gone:**

```
$ aws ec2 describe-security-groups --region us-east-2 \
    --filters "Name=group-name,Values=*icc*" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output table
sg-076c916a807936cee   icc-alb-sg          <- still exists, unmanaged

$ aws acm list-certificates --region us-east-2 \
    --query 'CertificateSummaryList[?contains(DomainName,`icc`)]...'
(empty)                                    <- no cert with 'icc' in the domain
```

So the destroy that removed the ALB left `icc-alb-sg` behind. That is consistent
with a partial destroy: security groups cannot be deleted while an ENI still
references them, so it very likely failed on a dependency at the time and was
never revisited.

- [x] Noted the leftovers — `sg-076c916a807936cee` (`icc-alb-sg`) survives

#### Before deleting anything: is that security group actually unused?

An unused security group costs nothing, but deleting one that is still referenced
breaks things silently. Two things reference a security group: network interfaces
that use it, and **rules in other security groups that allow traffic from it.**
The second is the one people forget.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

SG=sg-076c916a807936cee

echo "=== network interfaces using it (expect none) ==="
aws ec2 describe-network-interfaces --region us-east-2 \
  --filters "Name=group-id,Values=$SG" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status]' --output table

echo "=== other security groups whose rules reference it (expect none) ==="
aws ec2 describe-security-groups --region us-east-2 \
  --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='$SG']] || IpPermissionsEgress[?UserIdGroupPairs[?GroupId=='$SG']]].[GroupId,GroupName]" \
  --output table
```

- [x] No network interfaces — empty
- [x] No other security group in Perimeter references it in a rule — empty
- [x] Confirmed authoritatively by `delete-security-group` returning `Return: true`

The cert also deserves a wider look — the state resource was named
`aws_acm_certificate.icc`, but the *domain* on it may not contain the string
`icc`, so the filter above could miss it:

```bash
aws acm list-certificates --region us-east-2 \
  --query 'CertificateSummaryList[].[CertificateArn,DomainName,Status,InUse]' --output table
```

- [x] Accounted for every certificate listed — four, no `icc-alb` leftover

An unused ACM certificate is free and harmless. Worth deleting for tidiness, but
**never delete one that reports `InUse: true`.**

**Note on `crm.insightgrouppr.com`.** The live `crm-alb` leaf creates
`aws_acm_certificate.icc` — the same resource *name* the orphaned state carried,
because `crm-alb` was built from the `icc-alb` leaf. That certificate is `ISSUED`
and `InUse: true`, and the live `crm-alb` state manages it. Nothing was left
unmanaged by removing the old state object.

If the ARN in the backup matches `6d298cce-fc8e-4388-ae8c-a7566fa91c16`, then the
two states were both claiming one live certificate — a genuine dual-management
condition, now resolved with `crm-alb` as sole owner. Optional, purely for the
record, no action depends on it:

```bash
jq -r '.resources[] | select(.type=="aws_acm_certificate") | .instances[].attributes.arn' \
  ./icc-alb-orphan-state-backup.json
```

### 7b. Act on the answer

**Confirmed path for this case: scenario (c).** The ALB is gone. Delete the
orphaned security group first, *then* the state object — in that order, because
the state file is the only remaining record of what `icc-alb` consisted of.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

# Only after both reference checks above came back empty.
aws ec2 delete-security-group --group-id sg-076c916a807936cee --region us-east-2
```

If that returns `DependencyViolation`, something still references it — go back to
the reference checks rather than forcing it.

- [x] `sg-076c916a807936cee` deleted — `{"Return": true}`, no `DependencyViolation`

Then the state object, per the scenario (a) commands below — the cleanup is
identical.

---

**Scenario (a)** — the ARN belongs to the ALB now named `crm-alb`, and no extra
load balancer exists. Nothing is running unprotected. Remove the stale state so
two states can never fight over one set of resources:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "547368325532" ] && { echo "WRONG ACCOUNT ($ACCT) — need SharedServices"; exit 1; }

# Keep a copy first. This is the only record of those resource addresses.
aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate \
  ./icc-alb-orphan-state-backup.json --region us-east-2

# Then remove the object and its lock-table digest item.
aws s3 rm s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate \
  --region us-east-2
aws dynamodb delete-item --table-name lza-terraform-locks --region us-east-2 \
  --key '{"LockID":{"S":"lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate-md5"}}'
```

Deleting a state object is irreversible and the bucket may or may not be
versioned — **take the backup first, and confirm the ARN comparison before
running the removal.**

- [x] Backup taken — `./icc-alb-orphan-state-backup.json`
- [x] State object and lock digest removed

**Scenario (c)** — the ARN does not resolve. The resources are already gone and
the state is purely stale. Same cleanup as (a).

**Scenario (b) did not occur.** Retained here in case a similar orphan turns up
elsewhere: an extra live load balancer would be a public endpoint outside the WAF
programme, and the response would be to decommission it through the normal PR
flow — recreate a minimal leaf pointing at the existing state, then apply a
destroy with explicit `ALLOW-DESTROY`. Never delete it out of band, because that
leaves the same orphaned-state problem behind.

- [x] Outcome recorded in `waf-verification-record.md` under V10 and in `waf-verification-report.md` Correction 4

---

## Step 8 — osTicket HTTPS (not an SOW blocker, but the portal is on plain HTTP)

### 8a. Get the validation CNAME

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

aws acm describe-certificate --region us-east-2 \
  --certificate-arn arn:aws:acm:us-east-2:713939170920:certificate/8c2c365f-a408-4bbf-8f6e-187a28665057 \
  --query 'Certificate.DomainValidationOptions[].{Domain:DomainName,Name:ResourceRecord.Name,Value:ResourceRecord.Value,Status:ValidationStatus}' \
  --output table
```

- [ ] Send the `Name` → `Value` pair to the DNS admin as a **CNAME** at Network Solutions (`ns47`/`ns48.worldnic.com` are authoritative for `insightgrouppr.com`)

This is a **different** record from the first cert's. If anyone already added one for `tickets.*`, it is dead.

### 8b. Wait for ISSUED

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT"; exit 1; }

aws acm describe-certificate --region us-east-2 \
  --certificate-arn arn:aws:acm:us-east-2:713939170920:certificate/8c2c365f-a408-4bbf-8f6e-187a28665057 \
  --query 'Certificate.Status' --output text
```

- [ ] Status is `ISSUED`

### 8c. Enable HTTPS

```bash
git fetch insight-remote main
git checkout -b feat/osticket-enable-https insight-remote/main
```

In `terraform/live/perimeter/osticket-alb/terraform.tfvars` change:

```
enable_https = false
```

to

```
enable_https = true
```

```bash
git add -f terraform/live/perimeter/osticket-alb/terraform.tfvars
git commit -m "osticket-alb: enable HTTPS now that the cert is ISSUED

Attaches the HTTPS listener and 301-redirects HTTP. Gets the public ticket
portal off plain HTTP."
git push -u insight-remote feat/osticket-enable-https
gh pr create --base main --head feat/osticket-enable-https \
  --repo nebulariscloud/insight-codebase-infrastructure \
  --title "osticket-alb: enable HTTPS now that the cert is ISSUED" \
  --body "Cert 8c2c365f-a408-4bbf-8f6e-187a28665057 is ISSUED. Attaches the HTTPS listener and redirects HTTP to it. Expected plan: 1 listener created, HTTP listener default action changed to redirect. No destroys."
```

- [ ] Merged and applied
- [ ] `curl -I https://osticket.insightgrouppr.com/` returns a certificate and a 200/302
- [ ] Point the hostname at the ALB DNS name if not already

### 8d. osTicket target group is UNHEALTHY and the ALB is failing open

Found 2026-08-10 while closing step 6c. Not a WAF problem. **Do this before 8c.**

**Measured:**

```
$ curl -sS -o /dev/null -w '%{http_code}\n' \
    http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/
500                                    # raw ALB DNS name as Host

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -H 'Host: osticket.insightgrouppr.com' \
    http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/
301                                    # correct Host

$ aws elbv2 describe-target-health --target-group-arn "$tg" --region us-east-2
10.12.1.67   unhealthy   Target.ResponseCodeMismatch
```

#### What this means

**The target is unhealthy, and it has been serving traffic anyway.**

ALB target group health checks send `Host: <target-ip>:<port>` and **ELBv2 provides
no way to override that header** — there is no `HealthCheckHost` parameter, so this
cannot be fixed in the `alb` module. The check requests `/` with matcher
`200,301,302`; osTicket answers a request on an unrecognised host with 500;
500 is not in the matcher; `Target.ResponseCodeMismatch`.

Requests are still being served because of documented ALB behaviour: **when every
target in a target group is unhealthy, the ALB routes to all of them regardless of
health status.** Single target, unhealthy, so it fails open. That is why the
requests above got 500 and 301 rather than the 503 an ALB returns when it has
healthy targets available but none for this group.

So the portal has been running with **no health gating at all**:

- If osTicket genuinely breaks, the ALB cannot tell and has nowhere to shift traffic.
- Any future second target would be the only one considered, hiding this one's state.
- Deregistration-on-failure and instance-replacement logic keyed on target health will misfire.

#### The 301 does not prove the portal works

`enable_https = false`, so `certificate_arn` is empty, so the `alb` module's HTTP
listener uses a **forward** default action, not a redirect. **The 301 therefore
came from osTicket, not from the load balancer.** If osTicket is configured with
an `https://` helpdesk URL it will redirect there — and there is no 443 listener
on this ALB, so that redirect is a dead end for real users.

**Measured 2026-08-10 — this is the bad branch:**

```bash
$ curl -sSI -H 'Host: osticket.insightgrouppr.com' \
    http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/ | grep -i '^location:'
Location: https://osticket.insightgrouppr.com/
```

- [x] Recorded the `Location` value

**osTicket redirects to HTTPS, and this ALB has no HTTPS listener.** `enable_https
= false` → `certificate_arn` empty → the `alb` module creates no `aws_lb_listener`
on 443. The request chain for a real user is:

```
GET http://osticket.insightgrouppr.com/
  -> ALB :80 forwards to 10.12.1.67:80
  -> osTicket 301 -> https://osticket.insightgrouppr.com/
  -> ALB :443  ... no listener. Connection refused.
```

**The portal is unusable through this ALB.** Not degraded — unusable, for every
request that follows the redirect, which is every browser.

#### Is it down right now? No — this is pre-cutover

**Confirmed by the operator 2026-08-10:** `osticket.insightgrouppr.com` has not been
pointed at this load balancer, and the ACM validation CNAME is **deliberately
deferred to cutover** rather than overlooked. The help desk is still served by the
pre-migration host.

So nothing is broken for users, and nothing here is urgent. Two consequences that
do matter, though:

**1. `osticket-alb-waf` is not yet in front of real user traffic.** The Web ACL is
deployed, attached, logging and alarming correctly — SOW acceptance criterion 1 is
satisfied on the load balancer. But until DNS moves, the requests it inspects are
test traffic. That distinction is stated in `waf-sow-closeout.md` so it is not
mistaken for the osTicket application being protected today.

**2. Both faults must be fixed *before* cutover, not after.** The redirect-to-nowhere
and the unhealthy target group are latent. Cut DNS over with either still in place
and the help desk breaks at the worst possible moment:

- No 443 listener → every browser following osTicket's redirect hits a closed port.
- Permanently unhealthy target → the load balancer has no health signal at the exact
  point you most want one.

This is a **cutover prerequisite**, and it belongs on the osTicket migration
checklist rather than being carried as an open WAF item.

#### If the position changes, confirm with DNS

```bash
# `dig` is not installed on stock macOS shells. Any of these works:
nslookup osticket.insightgrouppr.com

# or, no external tooling:
python3 -c "import socket,sys
h='osticket.insightgrouppr.com'
try:
    print(socket.gethostbyname_ex(h))
except Exception as e:
    print('does not resolve:', e)"

# or via DNS-over-HTTPS, which also shows the record type:
curl -s -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=osticket.insightgrouppr.com&type=CNAME' | jq .
```

- [ ] Re-confirm before cutover: what the hostname resolves to

| Resolves to | Situation |
|---|---|
| The pre-migration host, or nothing | **Current state.** Not an outage. Fix both faults before moving DNS. |
| `osticket-alb-343594101.us-east-2.elb.amazonaws.com` | Cutover has happened. If either fault is still open at that point, the help desk is **down** — redirect to a closed port, and no health signal. |

#### Cutover ordering

Do these in order. The certificate is the long-lead item because it needs Insight
Group's DNS administrator.

1. **Validation CNAME added** (step 8a) → cert reaches `ISSUED`.
2. **`enable_https = true`** (step 8c) → adds the 443 listener and converts the
   port-80 listener to a redirect. This is what makes osTicket's own redirect land
   somewhere.
3. **Health check fixed** (below) → target reports `healthy`, so the load balancer
   has a real signal before it starts carrying users.
4. **Then** move `osticket.insightgrouppr.com` to the load balancer.

Steps 1–3 are all reversible and none of them affect the currently-live help desk,
so they can be done well ahead of the cutover window. Doing them *during* the window
is how a cutover turns into an outage.

If for some reason the portal has to go live on this load balancer before the
certificate lands, the only tolerable stopgap is disabling osTicket's HTTPS
redirect so it serves over plain HTTP — which means credentials travel unencrypted,
and is exactly why the redirect exists. Time-box it and treat it as a known risk.
Do **not** put a self-signed or unrelated certificate on the 443 listener; browsers
will refuse it.

#### Confirm the cause on the instance

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "395516496764" ] && { echo "WRONG ACCOUNT ($ACCT) — need Production"; exit 1; }

iid=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=private-ip-address,Values=10.12.1.67" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
echo "instance: $iid"

cid=$(aws ssm send-command --region us-east-2 \
  --document-name AWS-RunShellScript \
  --instance-ids "$iid" \
  --parameters 'commands=[
    "echo \"--- as the health check sees it (Host: IP) ---\"",
    "curl -s -o /dev/null -w \"%{http_code}\\n\" -H \"Host: 10.12.1.67\" http://127.0.0.1/",
    "echo \"--- as a user sees it ---\"",
    "curl -s -o /dev/null -w \"%{http_code}\\n\" -H \"Host: osticket.insightgrouppr.com\" http://127.0.0.1/",
    "echo \"--- does a static file bypass PHP? ---\"",
    "ls -la /var/www/html/ 2>/dev/null | head -20",
    "echo \"--- recent errors ---\"",
    "tail -30 /var/log/apache2/error.log 2>/dev/null || tail -30 /var/log/httpd/error_log 2>/dev/null"
  ]' \
  --query 'Command.CommandId' --output text)

sleep 15
aws ssm get-command-invocation --region us-east-2 \
  --command-id "$cid" --instance-id "$iid" \
  --query 'StandardOutputContent' --output text
```

- [ ] Confirmed the health check path returns a non-matching code when `Host` is the IP
- [ ] Identified the DocumentRoot

#### The fix

**Not by widening the matcher.** Adding 500 to `health_check_matcher` would make
the check pass while osTicket is genuinely broken, which is the same class of
mistake as the `notBreaching` alarms in rev 2 — a monitor that cannot report
failure.

**Do this instead:** serve a static file that Apache answers for any `Host`,
bypassing PHP entirely, and point the health check at it.

1. On the instance, create the file in the DocumentRoot:

   ```bash
   # via SSM, same pattern as above
   printf 'ok\n' | sudo tee /var/www/html/healthz
   sudo chmod 644 /var/www/html/healthz
   curl -s -o /dev/null -w 'healthz as IP host: %{http_code}\n' \
     -H 'Host: 10.12.1.67' http://127.0.0.1/healthz
   ```

   Must return **200**. If it returns 500, osTicket's rewrite rules are catching
   everything and need an exclusion for `/healthz`.

2. Then a one-line Terraform PR — in `terraform/live/perimeter/osticket-alb/terraform.tfvars`:

   ```hcl
   health_check_path    = "/healthz"
   health_check_matcher = "200"
   ```

   Expected plan: in-place update of `aws_lb_target_group`. **No replacement, no
   destroy** — health check attributes are mutable. If the plan shows a
   replacement, stop; that would drop the target registration.

3. After apply, re-check:

   ```bash
   aws elbv2 describe-target-health --target-group-arn "$tg" --region us-east-2 \
     --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
   ```

- [ ] `/healthz` returns 200 with the IP as `Host`
- [ ] tfvars PR merged and applied, plan showed an in-place update
- [ ] Target reports `healthy`
- [ ] Narrowing `health_check_matcher` to `200` confirmed — no longer accepting 301/302, which were only there to tolerate the redirect

This belongs to the osTicket migration workstream rather than the WAF SOW.
Cross-reference `.kiro/journal/2026-06-26-aheeva-cluster-migration-plan.md`, which
covers the move off Lightsail.

---

## Step 9 — Baselines for crm and osticket (after ~1 week of traffic)

They currently run on module-default thresholds (600 / 400 / 300 / 100).

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

for acl in crm-alb-waf osticket-alb-waf; do
  for rule in ALL AWS-CommonRuleSet AWS-KnownBadInputs AWS-IPReputation RateLimit; do
    echo "=== $acl / BlockedRequests / Rule=$rule ==="
    aws cloudwatch get-metric-statistics \
      --namespace AWS/WAFV2 --metric-name BlockedRequests \
      --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=$rule \
      --start-time "$(date -u -d '4 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --period 300 --statistics Sum --region us-east-2 \
      --query 'sort_by(Datapoints,&Sum)[-3:].[Timestamp,Sum]' --output table
  done
done
```

Then set per-ACL thresholds at roughly 1.5–2× observed peak in `terraform/live/perimeter/waf-monitoring/terraform.tfvars`, PR it, and update `waf-traffic-baseline.md`.

**Do not alarm on `AWS-IPReputation`** — it is commodity scanner noise and would produce pure alert fatigue.

- [ ] Baselines captured
- [ ] Thresholds set
- [ ] `waf-traffic-baseline.md` updated

---

## Step 10 — Housekeeping (optional)

### 10a. Backup tagging for migration targets

`cti-v7` held weeks of hand-configuration with no recovery point because the leaf carried no `BackupPlan` tag, so AWS Backup never covered it. Add `BackupPlan = "Continuous"` to the tags of any long-lived migration target.

- [ ] Reviewed migration-target leaves and tagged where appropriate

---

## Not on this list, deliberately

| Item | Why |
|---|---|
| cti-v7 rebuild | Parked via `.tf-skip`. Blocked on an Aheeva license hostid answer and a missing VPC BPA exclusion — neither is code. See `terraform/live/production/cti-v7/.tf-skip`. |
| PCI ALB deployment | Not an SOW deliverable. Account and VPC exist but hold no workload, cert or ALB. |
| CloudFront / API Gateway WAF | No such resources exist in this estate. |
| Geo-blocking | SOW says "if required". Capability built; needs a business answer on which countries are served first. |

**Removed from this table:** the `waf-logs` list refactor was previously listed here as a "nice-to-have… small follow-up". That was wrong. Two of the four protected resources were delivering **zero** log records as a direct result, which puts it inside the SOW logging deliverable. It is now **Step 6**, and the fix is PR #69.

---

## Definition of done

SOW is signable when **Steps 1–6** are complete. **Step 6 and Step 7 are both done.**

**Steps 1, 6 and 7 are done.** That leaves exactly one item on the Nebularis side:

- **Step 2** — the ~30 minute runbook exercise. The SOW says the runbook must be "tested and validated"; it is written but has never been run.

Then the four that need Insight Group: Bot Control, custom rules, and the two training sessions (steps 3, 4, 5).

**Step 8 is a cutover prerequisite for the osTicket migration, not a WAF sign-off item.** Nothing there is currently user-facing — DNS still points at the pre-migration host — but both faults in 8d must be closed before DNS moves. Track it on the migration checklist.

Steps 9 and 10 are operational follow-ups that gate nothing.
