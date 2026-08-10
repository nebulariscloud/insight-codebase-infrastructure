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
| `waf-design-decisions.md` | Engineering, audit, future maintainers | Why each design choice was made and what alternatives were considered. The "what we did and why" record. |
| `waf-verification-record.md` | Audit, SOW acceptance | Post-deployment verification: exact AWS CLI calls and observed responses, with pass criteria. Includes a retraction where a June conclusion proved wrong. |
| `waf-sow-closeout.md` | Insight Group + Nebularis | **Start here for SOW status.** Acceptance criteria mapped to deliverables, the four remaining items with how to close each, a completion checklist, and the sign-off block. Revised 2026-08-10. |

## Current SOW status

**Substantially complete.** All four public ALBs are protected, alarms are live on measured thresholds, and all documentation is delivered.

Four items remain, none blocked on engineering:

1. **Bot Control** — client decision: deploy or waive
2. **Two training sessions** — scripts are `waf-runbook.md` and `waf-tuning-guide.md`
3. **Runbook test** — a ~30 minute block/unblock exercise
4. **Custom rules** — review with app owners, then add rules or record the finding

See the completion checklist at the end of `waf-sow-closeout.md`.

## Code

- `terraform/modules/waf-managed/` — Web ACL (managed groups + rate-limit + IPSets + geo + Bot Control + custom rules)
- `terraform/modules/waf-logs/` — S3 + KMS log destination, optionally attaches to existing Web ACLs
- `terraform/modules/waf-monitoring/` — alarms + dashboard + SNS-by-severity
- `terraform/live/perimeter/waf-logs/` — perimeter log stack
- `terraform/live/perimeter/waf-monitoring/` — perimeter alarms + dashboard
- `aws-accelerator-config/custom-stacks/{ingress-alb,scriptcase-lb,pci-alb}.yaml` — the existing CFN-managed Web ACLs
