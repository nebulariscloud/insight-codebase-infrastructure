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
| `waf-verification-record.md` | Audit, SOW acceptance | Post-deployment verification: exact AWS CLI calls and observed responses, with pass criteria. |
| `waf-sow-closeout.md` | Insight Group + Nebularis | Final SOW status. Acceptance criteria mapped to deliverables. Sign-off block. |

## Code

- `terraform/modules/waf-managed/` — Web ACL (managed groups + rate-limit + IPSets + geo + Bot Control + custom rules)
- `terraform/modules/waf-logs/` — S3 + KMS log destination, optionally attaches to existing Web ACLs
- `terraform/modules/waf-monitoring/` — alarms + dashboard + SNS-by-severity
- `terraform/live/perimeter/waf-logs/` — perimeter log stack
- `terraform/live/perimeter/waf-monitoring/` — perimeter alarms + dashboard
- `aws-accelerator-config/custom-stacks/{ingress-alb,scriptcase-lb,pci-alb}.yaml` — the existing CFN-managed Web ACLs
