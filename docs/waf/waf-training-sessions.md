# WAF training sessions

Delivery material for the two training deliverables in the SOW. Written to be read from directly — no slides needed.

| Session | Audience | Length | Companion doc |
|---|---|---|---|
| A — Security operations walkthrough | Security team, on-call | ~60 min | `waf-runbook.md` |
| B — Rule management and tuning | Engineering | ~60 min | `waf-tuning-guide.md` |

Record delivery at the bottom of this file.

---

## Before either session

Have these open:

- The `perimeter-waf` CloudWatch dashboard, us-east-2, **Perimeter account `713939170920`**
- `docs/waf/waf-runbook.md`
- `docs/waf/waf-traffic-baseline.md`

And say this first, because it is the single most common way people waste an afternoon:

> Everything WAF lives in **Perimeter `713939170920`**. Production has no WAF at all. If you query WAF from Production you get zero metrics, no Web ACLs and no alarms — which looks exactly like a broken system. It cost us several hours on 10 August. Every command in our docs asserts the account first. Don't remove that line.

---

# Session A — Security operations walkthrough

**Audience:** whoever gets the alarm emails and has to act on them.
**Goal:** by the end, everyone can triage a WAF alarm without asking an engineer.

## A1. What we're protecting (5 min)

Four internet-facing load balancers, each with its own Web ACL:

| Load balancer | What's behind it | Web ACL |
|---|---|---|
| `ingress-alb` | Wazuh dashboard and API | `ingress-alb-waf` |
| `scriptcase-lb` | Scriptcase (PHP app) | `scriptcase-lb-waf` |
| `crm-alb` | ICC CRM APIs, prod + dev | `crm-alb-waf` |
| `osticket-alb` | osTicket portal | `osticket-alb-waf` |

Each Web ACL runs the same baseline: AWS managed rules for OWASP-style attacks, a known-bad-inputs set, AWS's malicious-IP reputation list, and a rate limit of 2000 requests per 5 minutes per source IP.

Say plainly: **WAF is not a silver bullet.** It filters known-bad patterns at the edge. It does not fix an application vulnerability, and it does not stop an attacker who looks like a normal user.

## A2. The one thing to understand about the alarms (10 min)

This is the part that matters most, so spend real time here.

There are 20 alarms — five per Web ACL. Three of them are threshold alarms, one is a rate-limit alarm, and one is a **liveness** alarm. They are not equally interesting.

**The most important framing:** blocked traffic is normal. The internet constantly scans every public endpoint. Our busiest Web ACL blocks more requests than it allows at peak, and that is **fine** — roughly 65% of those blocks are AWS's IP reputation list catching botnets and scanners. WAF doing its job.

So:

| Alarm | Means | Act? |
|---|---|---|
| `*-known-bad-inputs-blocks` | Someone is throwing known exploit payloads at us | **Yes** — look at it |
| `*-common-ruleset-blocks` | Someone is probing the app with OWASP-style attacks | **Yes** — look at it |
| `*-rate-limit-blocks` | A source is sustained-hammering us | **Yes** — usually abuse or a broken client |
| `*-blocked-total` | Overall block volume is unusually high | Maybe — often just a bigger scan wave |
| `*-no-metrics` | **The monitoring itself may be broken** | **Yes** — see A3 |

We deliberately do **not** alarm on the IP reputation rule. It's the biggest source of blocks and almost entirely commodity noise. Alarming on it would page you constantly for nothing, and you'd learn to ignore the emails. It's still on the dashboard if you want to look.

## A3. The `-no-metrics` alarm, and why it exists (10 min)

Tell this story. It teaches the lesson better than any explanation.

From 21 June to 10 August, these alarms **could not fire at all.** The monitoring code had the CloudWatch namespace written as `AWS/WAFv2` instead of `AWS/WAFV2` — one capital letter, and CloudWatch namespaces are case-sensitive. Every alarm was watching a namespace with nothing in it.

Worse: because the alarms are configured so that "no data" means "not breaching" (correct, since no data means nothing was blocked), an alarm watching a metric that doesn't exist reports **OK**. Green. Healthy-looking. For seven weeks.

Two real block spikes went unreported in that window. Both turned out to be scanner sweeps that WAF blocked correctly, so nothing bad got through — but nobody would have been told if it had.

The `-no-metrics` alarms are the fix. They work backwards from every other alarm: they fire when a Web ACL reports **nothing at all**. So "this alarm is watching nothing" becomes a thing that pages you, instead of a green tick.

**Practical upshot for the team:** if you see a `-no-metrics` alarm, do not assume the app is down. Assume the *monitoring* might be broken. The runbook has the check order.

## A4. Triage walkthrough (15 min)

Open `waf-runbook.md` and go through it live. Cover:

1. **Which Web ACL fired** — the alarm name tells you
2. **Which rule spiked** — the dashboard's "blocks by rule" panel per Web ACL
3. **What the traffic actually was** — `get-sampled-requests`, which shows real URIs, source IPs and user-agents

Then the triage table: one IP hammering one URL is a scraper; many IPs with randomised URIs and OWASP payloads is real attack pressure; a spike that lines up with a deploy is probably our own bad release.

If you have live data, pull real sampled requests during the session. Nothing lands better than seeing actual attack traffic against your own endpoint.

## A5. What you can and can't do yourself (10 min)

Be honest about the boundaries.

**You can:** read the dashboard, pull sampled requests, decide something needs blocking.

**You cannot:** change WAF rules directly. Everything goes through a pull request and the pipeline. That's deliberate — an unreviewed WAF change can take a site down as easily as an attacker can.

**In a genuine emergency**, the AWS console can add an IP to a deny set immediately. If you do that, open a PR the same day to make it permanent, otherwise the next Terraform run reverts it and nobody knows why the attacker came back.

**Escalation:** sustained high-severity alarm with no clear cause after 30 minutes → on-call lead. Confirmed real attack → loop in the application owner. PCI involved (when that exists) → compliance too.

## A6. Questions to expect (10 min)

**"Why are we blocking so much traffic?"**
Mostly automated scanners hitting every public IP on the internet. Normal and constant. The floor is never zero.

**"Are we under attack?"**
Check which rule is firing. IP reputation = background noise. CommonRuleSet or KnownBadInputs spiking = someone is actively probing the application.

**"Can WAF stop a DDoS?"**
It helps with application-layer floods via the rate limit. It does not stop a volumetric network attack — that's AWS Shield, which is on by default at the standard tier.

**"Something legitimate got blocked. What now?"**
Tell engineering with the timestamp and source IP. There's a documented tuning path. Do not disable a rule to make the complaint go away.

**"Why don't we block whole countries?"**
We can, and the capability is built. We haven't, because nobody has given us a defensible list of countries we serve. A wrong geo-block silently loses customers.

---

# Session B — Rule management and tuning

**Audience:** engineers who will change WAF rules.
**Goal:** by the end, everyone can add or tune a rule without breaking production.

## B1. How the rules are organised (10 min)

Everything is Terraform. The Web ACL lives in a reusable module, `terraform/modules/waf-managed`, and each leaf under `terraform/live/perimeter/` uses it.

Evaluation order matters — WAF stops at the first terminal action:

| Priority | Rule | Notes |
|---|---|---|
| 0 | Allow list | Vetted IPs skip **everything**, including the rate limit |
| 1 | Deny list | Known-bad IPs blocked outright |
| 2 | Geo gate | Not currently used |
| 3 | `AWS-CommonRuleSet` | OWASP-style, with Count overrides |
| 4 | `AWS-KnownBadInputs` | Known exploit payloads |
| 5 | `AWS-IPReputation` | AWS's malicious IP list |
| 6 | `AWS-AnonymousIP` | Off by default |
| 7 | `AWS-BotControl` | Off by default — costs money |
| 10 | Rate limit | 2000 / 5 min / IP |
| 100+ | Custom rules | None defined yet |

Emphasise priority 0: an allow-list entry bypasses every protection. Use it sparingly and only for sources you've actually verified.

## B2. The Count-then-promote discipline (15 min)

The single most important habit. **Every new rule starts in Count mode.**

Count means "match and record, don't block." You watch it for a week, see what it would have blocked, and only then promote it to Block.

Show the real example in our config. Four sub-rules of `AWS-CommonRuleSet` are permanently in Count on `ingress-alb-waf`:

- `EC2MetaDataSSRF_BODY` — Wazuh legitimately sends `127.0.0.1` in health-check bodies
- `SizeRestrictions_BODY` — Wazuh's index-pattern lookups send large JSON
- `GenericRFI_BODY` and `GenericRFI_QUERYARGUMENTS` — Wazuh payloads contain URL-like values

Left at their default Block, Wazuh breaks. This is exactly the kind of thing you only discover by observing rather than assuming.

Same reason `SizeRestrictions_BODY` stays in Count on osTicket: ticket attachments are large multipart uploads.

## B3. How to find a false positive (10 min)

Demonstrate live:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

ARN=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
  --query "WebACLs[?Name=='ingress-alb-waf'].ARN | [0]" --output text)

aws wafv2 get-sampled-requests --web-acl-arn "$ARN" \
  --rule-metric-name AWS-CommonRuleSet --scope REGIONAL --region us-east-2 \
  --max-items 50 \
  --time-window StartTime=$(date -u -d '2 hours ago' +%s),EndTime=$(date -u +%s) \
  --query 'SampledRequests[].[Timestamp,Action,RuleNameWithinRuleGroup,Request.ClientIP,Request.URI]' \
  --output table
```

`RuleNameWithinRuleGroup` is the exact sub-rule name. That's what goes into the Count-override list.

## B4. Where the thresholds came from (10 min)

Walk through `waf-traffic-baseline.md`. The point: these numbers are **measured**, not guessed.

Measured over four days:

| | ingress peak blocked / 5 min | scriptcase peak |
|---|---|---|
| All rules | 2464 | 297 |
| IP reputation | 1712 | 182 |
| CommonRuleSet | 419 | 231 |
| KnownBadInputs | 387 | 107 |
| Rate limit | 0 | 0 |

Two things to draw out:

**The thresholds differ per Web ACL by design.** Peak block volume differs about eightfold. One global number would leave Scriptcase effectively unmonitored while making Ingress alarm constantly.

**The profiles differ too.** On Ingress, IP reputation dominates. On Scriptcase, CommonRuleSet dominates — it's a PHP app and attracts more application-layer probing. Different apps attract different attacks.

Also note the rate limit never fired in four days. That's evidence it's well calibrated, not evidence it's useless.

## B5. Making a change (10 min)

Walk the flow:

1. Branch from `main`
2. Edit the leaf's `terraform.tfvars` or its `module "waf"` block
3. `terraform fmt -check -recursive terraform/`
4. Commit, push, open a PR
5. **Read the plan comment.** Confirm it matches what you intended
6. Merge → applies automatically

Then cover the guardrails, and why each exists:

- **Destroy guard.** Any apply whose plan deletes or replaces a resource is blocked unless the PR explicitly authorises it. This exists because a fan-out apply destroyed a production EC2 instance on 8 August.
- **Plan-then-apply-that-plan.** The pipeline applies a saved, inspected plan. It used to re-plan at apply time and run whatever it found, unseen.
- **Concurrency group.** Runs queue instead of racing for state locks.
- **Dispatch-apply.** A single leaf can be re-applied on demand without a dummy commit.
- **`.tf-skip`.** A broken leaf can be parked so it stops failing every unrelated PR.

Make the point explicitly: **a change to `terraform/modules/**` fans out to every leaf.** So a one-character module fix plans and applies all 23. That's how the EC2 instance was lost. Treat module changes with more care than leaf changes.

## B6. Exercise (5 min)

Talk through, don't necessarily run:

> osTicket's login page is getting credential-stuffed. Add a rate limit of 100 requests per 5 minutes per IP on `/scp/login.php` only, without affecting the rest of the site.

Answer: a `custom_rules` entry with a `rate_based_statement` and `scope_down_uri_starts_with = "/scp/login.php"`, priority in the 100s. Example is in `waf-tuning-guide.md`.

Good follow-ups: What would you set the limit to? (Look at the baseline first.) Would you start it in Count? (Yes.) How would you know it worked?

---

## What NOT to do — both sessions

Worth saying out loud:

- **Don't disable a managed rule group** to fix one false positive. Override the specific sub-rule to Count.
- **Don't add to the allow list** without verifying the source. Priority 0 bypasses everything.
- **Don't change alarm thresholds** to stop an alarm being annoying. Find out why it's firing.
- **Don't make console changes** without a same-day PR. Terraform will revert them silently.
- **Don't assume a green alarm means healthy.** That's exactly what fooled us for seven weeks. Trust the `-no-metrics` alarms.
- **Don't query WAF from the Production account.** Perimeter `713939170920`.

---

## Delivery record

### Session A — Security operations walkthrough

- Date: ________________
- Delivered by: ________________
- Attendees: ________________________________________________
- Questions raised needing follow-up: ________________________
- Actions arising: ____________________________________________

### Session B — Rule management and tuning

- Date: ________________
- Delivered by: ________________
- Attendees: ________________________________________________
- Questions raised needing follow-up: ________________________
- Actions arising: ____________________________________________

Once both are recorded, tick items 2 and 3 in `waf-finish-checklist.md`.
