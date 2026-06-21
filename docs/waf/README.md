# WAF documentation

Operational docs for the AWS WAF deployment. Written for the SOW deliverables (`Statement of Work — AWS WAF Implementation`, March 2026).

| File | Audience | Purpose |
|---|---|---|
| `waf-architecture.md` | Engineering, audit | What's deployed, how it's wired, where ownership lives. |
| `waf-runbook.md` | On-call security | Step-by-step response when an alarm fires. |
| `waf-tuning-guide.md` | Engineering | How to add / promote / roll back rules without breaking things. |
| `waf-traffic-baseline.md` | Engineering | Captured traffic baseline + threshold derivations. Updated weekly during the first month, then monthly. |

Code lives in:

- `terraform/modules/waf-managed/` — Web ACL (managed groups + rate-limit + IPSets + geo + Bot Control + custom rules)
- `terraform/modules/waf-logs/` — S3 + KMS log destination, optionally attaches to existing Web ACLs
- `terraform/modules/waf-monitoring/` — alarms + dashboard + SNS-by-severity
- `terraform/live/perimeter/waf-logs/` — perimeter log stack
- `terraform/live/perimeter/waf-monitoring/` — perimeter alarms + dashboard
- `aws-accelerator-config/custom-stacks/{ingress-alb,scriptcase-lb,pci-alb}.yaml` — the existing CFN-managed Web ACLs
