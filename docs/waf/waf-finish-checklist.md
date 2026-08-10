# WAF — finish checklist

Everything still required to close the SOW, in order, with the exact commands.

Work top to bottom. Steps marked **[HUMAN]** are conversations or sessions with no command to run. Everything else is copy-paste.

Status as of 2026-08-10: implementation is complete and verified. Four SOW items and one verification remain.

---

## Account cheat sheet

Every command block below asserts the account before doing anything. Get this wrong and the output looks like a broken system — it cost hours on 2026-08-10.

| Account | ID | Holds |
|---|---|---|
| **Perimeter** | `713939170920` | All Web ACLs, all 4 public ALBs, WAF logs bucket, alarms, dashboard, SNS |
| Production | `395516496764` | shared-prod VPC, EC2, RDS. **No WAF.** |
| SharedServices | `547368325532` | Terraform state bucket + lock table |

---

## Step 0 — Merge the two open docs PRs

- [ ] **PR #67** — SOW closeout revision
- [ ] **PR #58** — cti-v7 operations docs

Docs only. `detect` yields `any=false`, so nothing plans or applies.

```bash
gh pr merge 67 --repo nebulariscloud/insight-codebase-infrastructure --squash
gh pr merge 58 --repo nebulariscloud/insight-codebase-infrastructure --squash
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

## Step 6 — osTicket HTTPS (not an SOW blocker, but the portal is on plain HTTP)

### 6a. Get the validation CNAME

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

### 6b. Wait for ISSUED

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT"; exit 1; }

aws acm describe-certificate --region us-east-2 \
  --certificate-arn arn:aws:acm:us-east-2:713939170920:certificate/8c2c365f-a408-4bbf-8f6e-187a28665057 \
  --query 'Certificate.Status' --output text
```

- [ ] Status is `ISSUED`

### 6c. Enable HTTPS

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

## Step 7 — Baselines for crm and osticket (after ~1 week of traffic)

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

## Step 8 — Housekeeping (optional)

### 8a. Orphaned `icc-alb` state file

`crm-alb` was renamed from `icc-alb` in PR #45, and a state file remains at the old key. Confirm it is not a second state tracking the same ALB.

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "547368325532" ] && { echo "WRONG ACCOUNT ($ACCT) — need SharedServices"; exit 1; }

aws s3 ls s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/ --region us-east-2
aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate - --region us-east-2 \
  | jq '{serial, resource_count: (.resources | length), addresses: [.resources[].type + "." + .resources[].name] | unique}'
```

- [ ] If `resource_count` is 0, delete the object and its lock-table `-md5` item
- [ ] If non-zero, work out which state owns the live ALB before touching anything

### 8b. Backup tagging for migration targets

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
| PR 3 (`waf-logs` list refactor) | Nice-to-have. `waf-logs` currently covers ingress + scriptcase; adding crm + osticket is a small follow-up. |

---

## Definition of done

SOW is signable when Steps 1–5 are complete. Steps 6–8 are operational follow-ups that do not gate sign-off — though Step 6 is worth prioritising, because a public ticket portal is currently served over plain HTTP.
