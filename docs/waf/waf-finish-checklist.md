# WAF — finish checklist

Everything still required to close the SOW, in order, with the exact commands.

Work top to bottom. Steps marked **[HUMAN]** are conversations or sessions with no command to run. Everything else is copy-paste.

**Status as of 2026-08-10.** The filtering layer is deployed and verified on all four internet-facing applications. Remaining:

| | Item | Who |
|---|---|---|
| Step 1 | Dashboard visual confirmation | Nebularis |
| Step 2 | Runbook exercise | Nebularis |
| Step 3 | Bot Control decision | **Insight Group** |
| Step 4 | Custom rules review | **Insight Group** (4 owner conversations) |
| Step 5 | Two training sessions | Both |
| ~~Step 6~~ | ~~Log delivery + alarm inventory~~ | **DONE 2026-08-10** |
| Step 7 | Orphaned `icc-alb` state — **security question closed**, cleanup left | Nebularis |
| Step 8 | osTicket HTTPS, plus **8d: the HTTP 500** | Insight Group's DNS admin, then Nebularis |
| Step 9 | crm / osticket baselines | Nebularis, after a week of data |

Steps 6 and 7 were added after a wider verification round on 2026-08-10 found that two of the four Web ACLs had never delivered a log record, and that an orphaned state file claims 13 resources. Detail in `waf-verification-report.md`.

**Progress as of 2026-08-10 — everything with an unknown answer is now settled:**

- **Step 6 complete.** PR **#69** merged and applied. All four Web ACLs delivering log records: 28830 / 15502 / 1 / 4. The SOW logging deliverable covers every protected resource.
- **Alarm inventory: 20.** The earlier six-alarm reading was stale, from before #62's apply.
- **Account-wide load balancer enumeration: 7 LBs, 4 ALBs, all four with a Web ACL, no `icc-alb`.** The orphaned state does not correspond to a live unprotected endpoint. Step 7 drops from "possible security exposure" to state cleanup.
- **PRs #58, #69 and #70 all merged**; nothing open.
- **New, unrelated:** osTicket returned HTTP **500** when reached by the ALB's raw DNS name. Probably an artefact of requesting by IP rather than by hostname, but unverified. **Step 8d.**

> **Priority order:** step 8d (two commands — is the ticket portal actually working?), then step 1 (open the dashboard), then step 2 (the ~30 minute runbook exercise). Step 7 is tidying. Steps 3–5 need Insight Group.

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

## Step 1 — Confirm the dashboard populates

Last unverified item on SOW acceptance criterion 4. The dashboard rendered empty until the namespace fix; nobody has looked since.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

# Dashboard exists?
aws cloudwatch list-dashboards --region us-east-2 \
  --query 'DashboardEntries[?DashboardName==`perimeter-waf`].[DashboardName,LastModified]' \
  --output table

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

- [ ] All four Web ACLs report datapoints > 0
- [ ] Open the dashboard and eyeball it:
      https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/perimeter-waf

`crm-alb-waf` and `osticket-alb-waf` may show 0 briefly if their ALBs are idle — re-run after some traffic.

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

## Step 7 — Clean up the orphaned `icc-alb` state

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
| **(a)** | Same resources `crm-alb` now manages | Possible. Dual-management hazard — two states claiming one set of resources. No cost, no exposure. |
| **(b)** | A separate `icc-alb` ALB is still running | **RULED OUT 2026-08-10** — no `icc-alb` in the account. |
| **(c)** | Resources already gone, state purely stale | Possible. |

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

- [ ] Recorded the ALB name / ARN / DNS name from the orphaned state
- [ ] Compared against `crm-alb-142110994.us-east-2.elb.amazonaws.com` — match means (a), no match means (c)

While in there, since the state also claims a security group and a certificate:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

aws ec2 describe-security-groups --region us-east-2 \
  --filters "Name=group-name,Values=*icc*" \
  --query 'SecurityGroups[].[GroupId,GroupName,Description]' --output table

aws acm list-certificates --region us-east-2 \
  --query 'CertificateSummaryList[?contains(DomainName,`icc`)].[CertificateArn,DomainName,Status]' \
  --output table
```

- [ ] Noted whether an unmanaged `icc*` security group or certificate is left behind

Neither costs anything unused, but an unmanaged security group in Perimeter is worth knowing about and an unused cert is worth deleting for tidiness.

### 7b. Act on the answer

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

- [ ] Backup taken
- [ ] State object and lock digest removed

**Scenario (c)** — the ARN does not resolve. The resources are already gone and
the state is purely stale. Same cleanup as (a).

**Scenario (b) did not occur.** Retained here in case a similar orphan turns up
elsewhere: an extra live load balancer would be a public endpoint outside the WAF
programme, and the response would be to decommission it through the normal PR
flow — recreate a minimal leaf pointing at the existing state, then apply a
destroy with explicit `ALLOW-DESTROY`. Never delete it out of band, because that
leaves the same orphaned-state problem behind.

- [ ] Outcome recorded in `waf-verification-record.md` under V10, and V10 updated in `waf-verification-report.md`

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

### 8d. osTicket returned HTTP 500 — is the portal actually healthy?

Found on 2026-08-10 while closing step 6c. Requesting the ALB by its raw DNS name
returned **500**.

This is not a WAF problem and not a load balancer problem. The `osticket-alb`
listener is a plain forward to `10.12.1.67:80` with no host-based routing rules
and no fixed-response default action, so a 500 means a target answered and the
application errored. An ALB with no healthy targets returns 503; a malformed
target response returns 502.

**Most likely a testing artefact, not a fault.** osTicket stores an absolute
helpdesk URL in `ost-config.php` and commonly errors when reached on an
unexpected hostname. The target group health check uses `/` with matcher
`200,301,302` and sends the target IP as `Host`, so the target can be healthy
while a wrong-`Host` request 500s. Consistent with what was seen — but unverified.

```bash
# Same request, correct hostname.
curl -sS -o /dev/null -w 'correct Host: %{http_code}\n' \
  -H 'Host: osticket.insightgrouppr.com' \
  http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/

ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

tg=$(aws elbv2 describe-target-groups --region us-east-2 \
  --query "TargetGroups[?contains(TargetGroupName,'osticket')].TargetGroupArn | [0]" \
  --output text)
aws elbv2 describe-target-health --target-group-arn "$tg" --region us-east-2 \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason]' \
  --output table
```

- [ ] Correct-`Host` request returns 200, 301 or 302
- [ ] Target `10.12.1.67` reports `healthy`

If both pass, the portal is fine and the 500 was an artefact of testing by IP —
note it and move on.

If the correct-`Host` request also 500s, or the target is unhealthy, it is a real
osTicket fault and belongs to the migration workstream, not this checklist.
Starting points: whether Apache/PHP is running on `10.12.1.67`, whether osTicket
can reach `iccmaindb`, and the PHP error log. Cross-reference
`.kiro/journal/2026-06-26-aheeva-cluster-migration-plan.md`, which covers the
osTicket move off Lightsail.

Worth settling before step 8c flips HTTPS on — no point publishing a TLS
endpoint in front of an application returning 500.

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

SOW is signable when **Steps 1–6** are complete. **Step 6 is done.**

That leaves **step 1** (open the dashboard) and **step 2** (the runbook exercise) on the gating list — plus steps 3, 4 and 5, which need Insight Group.

**Step 7 no longer gates sign-off.** It was in the gating set while it might have been an unprotected public load balancer. The account-wide enumeration ruled that out, so it is state cleanup — do it, but it does not hold up the SOW.

Steps 8–10 are operational follow-ups. Step 8 is worth prioritising anyway: the ticket portal is on plain HTTP, which is a live exposure even though it is not a WAF defect, and **8d may mean the portal is not working at all.**

**Shortest path to signable:**

1. **Step 8d** — two commands. Is the ticket portal actually serving? Do this first; it is the only thing on the list that might be an active outage.
2. **Step 1** — open the dashboard, confirm the widgets populate.
3. **Step 2** — the ~30 minute runbook exercise.

Then the four Insight Group items: Bot Control, custom rules, and the two training sessions.
