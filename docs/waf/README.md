# WAF documentation

Operational and project docs for the AWS WAF deployment. Written for the SOW deliverables (`Statement of Work — AWS WAF Implementation`, March 2026).

## Operational

| File | Audience | Purpose |
|---|---|---|
| `waf-architecture.md` | Engineering, audit | What's deployed, how it's wired, where ownership lives. |
| `waf-runbook.md` | On-call security | Step-by-step response when an alarm fires. |
| `waf-tuning-guide.md` | Engineering | How to add / promote / roll back rules without breaking things. |
| `waf-traffic-baseline.md` | Engineering | Captured traffic baseline + threshold derivations. Updated weekly during the first month, then monthly. |

## Project / audit

| File | Audience | Purpose |
|---|---|---|
| `waf-verification-report.md` | **Insight Group** | **The client deliverable.** Every verification we ran, in plain English: what passed, what failed, what is not yet verified, and four corrections to our own earlier reporting. |
| `waf-design-decisions.md` | Engineering, audit, future maintainers | Why each design choice was made and what alternatives were considered. The "what we did and why" record. |
| `waf-verification-record.md` | Audit, engineering | Technical appendix to the report: exact AWS CLI calls and observed responses, with pass criteria. 11 checks across 3 rounds, including a retraction where a June conclusion proved wrong. |
| `waf-sow-closeout.md` | Insight Group + Nebularis | SOW status and reasoning. Acceptance criteria mapped to deliverables, the remaining items, and the sign-off block. Revised 2026-08-10. |
| `waf-finish-checklist.md` | Whoever is finishing the work | **The execution doc.** Every remaining step in order with copy-paste commands. |
| `waf-training-sessions.md` | Whoever delivers the training | Ready-to-read material for both required sessions, with delivery record. |
| `waf-custom-rules-finding.md` | Engineering + app owners | Template for the custom-rules review, the questions to ask, and the written finding. |

## Which doc do I want?

| I want to… | Read |
|---|---|
| Hand Insight Group a record of what we verified | `waf-verification-report.md` |
| Check the exact command and output behind a claim | `waf-verification-record.md` |
| Know where the SOW stands and what's owed | `waf-sow-closeout.md` |
| **Finish the remaining work** | **`waf-finish-checklist.md`** |
| Understand why a design choice was made | `waf-design-decisions.md` |
| Respond to an alarm right now | `waf-runbook.md` |

`waf-finish-checklist.md` is the execution doc: every remaining step in order, with the exact commands to paste. Steps marked **[HUMAN]** are conversations or sessions with nothing to run. Work top to bottom.

Use `waf-sow-closeout.md` for **status and reasoning**. Use `waf-finish-checklist.md` to **get it done**.

Supporting material for the remaining items:

- `waf-training-sessions.md` — ready-to-deliver material for both required sessions
- `waf-custom-rules-finding.md` — template for the custom-rules review and its written finding

## Current SOW status

**Substantially complete.** All four public ALBs are inspected by WAF with OWASP-aligned managed rule groups and per-IP rate limiting, alarms are live on measured thresholds, and all documentation is delivered.

**Closed 2026-08-10:**

- **WAF logging on all four Web ACLs, confirmed delivering** — 28830 / 15502 / 1 / 4. **PR #69** merged and applied.
- **Alarm inventory confirmed at 20.** The earlier six-alarm reading was stale.
- **Account-wide load balancer enumeration: 4 ALBs, all with a Web ACL, no `icc-alb`.** The orphaned state file does not correspond to a live unprotected endpoint, and the ALB inventory is now known complete.

**Nebularis to close — engineering, no client input, and no additional charge:**

1. **Dashboard visual confirmation** — checklist step 1. Last unverified item on SOW acceptance criterion 4.
2. **Runbook exercise** — ~30 minutes, checklist step 2.
3. **Remove the orphaned `icc-alb` security group and state object** — resolved to a destroyed ALB with a partial destroy; `sg-076c916a807936cee` survives unmanaged. Hygiene, not exposure. Checklist step 7.

**Outside the WAF SOW, but the most serious thing on this page:**

4. **The osTicket portal is unusable through its load balancer.** Not a WAF defect — the Web ACL inspects and logs that traffic correctly. But the target group has been unhealthy the whole time behind a load balancer that was failing open, and osTicket redirects to an HTTPS listener that does not exist. Whether it is a live outage turns on one DNS lookup. **This puts the ACM validation CNAME on the critical path.** Checklist step 8d.

**Requires Insight Group:**

4. **Bot Control** — decision: deploy or waive in writing
5. **Custom rules** — four short owner conversations, then rules or a recorded finding
6. **Two training sessions** — scripts are `waf-runbook.md` and `waf-tuning-guide.md`
7. **osTicket DNS validation CNAME** — **now on the critical path, not cosmetic.** Without the certificate there is no HTTPS listener, and without the listener osTicket's redirect has nowhere to land. One CNAME at Network Solutions; values are in `waf-sow-closeout.md`. See item 4 above.

The items closed above were found by a wider verification round on 2026-08-10, after the June closeout had already reported those areas as complete. The findings, why they went unnoticed, and how they resolved are written up in `waf-verification-report.md`; status and the payment position are in `waf-sow-closeout.md`.

## Code

- `terraform/modules/waf-managed/` — Web ACL (managed groups + rate-limit + IPSets + geo + Bot Control + custom rules)
- `terraform/modules/waf-logs/` — S3 + KMS log destination, optionally attaches to existing Web ACLs
- `terraform/modules/waf-monitoring/` — alarms + dashboard + SNS-by-severity
- `terraform/live/perimeter/waf-logs/` — perimeter log stack
- `terraform/live/perimeter/waf-monitoring/` — perimeter alarms + dashboard
- `aws-accelerator-config/custom-stacks/{ingress-alb,scriptcase-lb,pci-alb}.yaml` — the existing CFN-managed Web ACLs
