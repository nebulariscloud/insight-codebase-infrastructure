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
| **Step 6** | **Log delivery for all 4 Web ACLs + alarm inventory** | **Nebularis — closes closeout rev 3 findings 1 and 3** |
| **Step 7** | **Orphaned `icc-alb` state — possible unprotected public ALB** | **Nebularis — closes closeout rev 3 finding 2** |
| Step 8 | osTicket HTTPS | Insight Group's DNS admin, then Nebularis |
| Step 9 | crm / osticket baselines | Nebularis, after a week of data |

Steps 6 and 7 were added after a wider verification round on 2026-08-10 found that two of the four Web ACLs had never delivered a log record, and that an orphaned state file claims 13 live resources. Detail in `waf-verification-report.md`.

> **Priority order if you only have an hour:** step 6, then step 7, then step 1. Those three are the ones where we currently do not know the answer. Everything else is a scheduled conversation or a known quantity.

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

**#69 is the only one that plans or applies.** Merge it first so its apply has
finished before you run step 6.

- [ ] **PR #69** — `waf-logs`: enrol `crm-alb-waf` and `osticket-alb-waf` in logging. **Plans and applies.** Expected plan: `2 to add, 0 to change, 0 to destroy`. Read the plan comment before merging; if it shows any destroy or replace, stop.
- [ ] **PR #70** — this checklist revision, the verification report, closeout rev 3. Docs only.
- [ ] **PR #58** — cti-v7 operations docs. Docs only.

```bash
R=nebulariscloud/insight-codebase-infrastructure

# Read #69's plan comment first.
gh pr view 69 --repo "$R" --comments | tail -60

gh pr merge 69 --repo "$R" --squash
gh pr merge 70 --repo "$R" --squash
gh pr merge 58 --repo "$R" --squash
```

Docs-only PRs yield `any=false` from `detect`, so nothing plans or applies for
those two.

Already merged, listed so the numbering isn't confusing: **#67** (closeout rev 2)
and **#68** (training material, custom-rules template).

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

- [ ] **PR #69 merged and applied.** Plan should read `2 to add, 0 to change, 0 to destroy`. If it shows a destroy or replace, stop and re-read the PR body — no `ALLOW-DESTROY` is expected for this change.
- [ ] All four report `dest = arn:aws:s3:::aws-waf-logs-713939170920-us-east-2`
- [ ] All four report `objects` > 0

`crm-alb-waf` and `osticket-alb-waf` may sit at 0 for a few minutes if their ALBs
are idle. Generate a request against each and re-run before concluding anything.

**Then record the result in `waf-verification-record.md` under V9** and flip V9
from FAIL to Pass in both that file and `waf-verification-report.md`.

### 6b. Alarm inventory — 20 expected, currently unconfirmed

PR #62 expanded the alarm set from 6 to 20. Internal notes record that as
verified; a later capture showed only the original 6 names. The two records
cannot be reconciled, so V8 is recorded as **not verified**. Settle it:

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

- [ ] Count is **20** (5 per Web ACL × 4)
- [ ] Every `Namespace` reads `AWS/WAFV2` — capital `V`, this is the June defect
- [ ] All four `*-no-metrics` liveness alarms present and `OK`. `OK` here is the meaningful signal: they alarm on *absence*, so `OK` positively confirms metrics are arriving
- [ ] Thresholds match the baseline: ingress 4000 / 700 / 600 / 100 · scriptcase 600 / 400 / 250 / 100 · crm + osticket on module defaults 600 / 400 / 300 / 100

If the count comes back **6**, the `waf-monitoring` leaf never applied. Its
original apply was cancelled and re-driven by dispatch; re-drive it again:

```bash
gh workflow run terraform.yml \
  --repo nebulariscloud/insight-codebase-infrastructure \
  -f leaf=terraform/live/perimeter/waf-monitoring \
  -f apply=true
```

- [ ] If re-driven: re-run the inventory command above and confirm 20

**Then record the outcome in `waf-verification-record.md` under V8** and update
V8 in `waf-verification-report.md`.

---

## Step 7 — Resolve the orphaned `icc-alb` state (possible unprotected public ALB)

**Do this before signing off on acceptance criterion 1.** Step 1 concluded "4 of
4 ALBs protected"; that is only as good as the list of ALBs it was checked
against.

`crm-alb` was renamed from `icc-alb` in PR #45. The old state object was never
removed and still claims **13 live resources**:

```
s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate
serial 2 · lineage 4d7fafc8-9e41-1cdf-d9e3-14c241ab8901 · modified 2026-07-17

aws_lb.this · aws_security_group.alb · aws_acm_certificate.icc
aws_lb_target_group.{this,dev} · aws_lb_target_group_attachment.{prod,dev}
aws_lb_listener.http · aws_lb_listener_rule.{prod_host,dev_host}
aws_vpc_security_group_{ingress_rule.http,ingress_rule.https,egress_rule.to_targets}
```

No leaf on `main` points at it. Two possibilities:

| | Scenario | Implication |
|---|---|---|
| **(a)** | Same resources `crm-alb` now manages | Dual-management hazard. No extra cost or exposure. |
| **(b)** | A separate `icc-alb` ALB is still running | Internet-facing, outside the WAF programme, unmonitored, billing. |

### 7a. Which one is it

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

echo "=== every load balancer AWS knows about ==="
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,Type,DNSName]' --output table

echo "=== and their WAF status ==="
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[?Type==`application`].LoadBalancerArn' --output text \
  | tr '\t' '\n' | while read -r arn; do
      [ -z "$arn" ] && continue
      acl=$(aws wafv2 get-web-acl-for-resource --resource-arn "$arn" --region us-east-2 \
        --query 'WebACL.Name' --output text 2>/dev/null || echo "NONE")
      printf "%-70s WAF=%s\n" "${arn##*/loadbalancer/}" "$acl"
    done
```

Then, with credentials that can read the SharedServices state bucket:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "547368325532" ] && { echo "WRONG ACCOUNT ($ACCT) — need SharedServices"; exit 1; }

aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate - \
  --region us-east-2 \
  | jq -r '.resources[] | select(.type=="aws_lb") | .instances[].attributes | "\(.name)  \(.arn)  \(.dns_name)"'
```

- [ ] Recorded the ALB name / ARN / DNS name from the orphaned state
- [ ] Compared against the live load balancer list

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

**Scenario (b)** — an extra load balancer exists. That is a public endpoint
outside the WAF programme.

- [ ] Confirm what it serves and whether any DNS record still points at it
- [ ] If dead: decommission through the normal PR flow — recreate a minimal `icc-alb` leaf pointing at the existing state, then apply a destroy with explicit `ALLOW-DESTROY` authorisation. Do **not** delete it out of band; that leaves the same orphaned-state problem behind.
- [ ] If live: it needs a Web ACL immediately. Same pattern as `crm-alb` — `enable_waf = true` plus a `waf-managed` module block.

**Scenario (c)** — the ARN does not resolve at all. The resources are already
gone and the state is purely stale. Same cleanup as scenario (a).

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

SOW is signable when **Steps 1–7** are complete.

Steps 6 and 7 are in that set, not outside it. Step 6 is part of the SOW logging deliverable, and step 7 gates the claim in acceptance criterion 1 that every public ALB is protected — a claim that is only as good as the list of ALBs it was checked against.

Steps 8–10 are operational follow-ups that do not gate sign-off, though step 8 is worth prioritising because a public ticket portal is currently served over plain HTTP.
