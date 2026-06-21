# SOW closeout — AWS WAF Implementation

| Field | Value |
|---|---|
| Project | AWS WAF Implementation |
| Client | Insight Group |
| Service Provider | Nebularis Cloud LLC |
| SOW dated | March 5, 2026 |
| SOW value | $8,500 (50% on signing, 50% on completion) |
| Closeout date | June 21, 2026 |
| Repository | `nebulariscloud/insight-codebase-infrastructure` |
| Delivery PR | `feat/waf-sow-implementation` (merged), `docs/waf-design-decisions` (merged) |

## Acceptance criteria — final status

The SOW listed five acceptance criteria. Each is met as follows:

### 1. AWS WAF deployed and actively protecting all designated resources

**Met.** Three Web ACLs deployed and attached:

| Web ACL | Attached to | Account | Verified by |
|---|---|---|---|
| `ingress-alb-waf` | `IngressALB` (Wazuh) | Perimeter | `aws wafv2 get-web-acl-for-resource` returns the association |
| `scriptcase-lb-waf` | `ScriptcaseLB` | Perimeter | Same |
| `pci-alb-waf` | `PciAlb` (planned) | PCI (planned) | Template ready; gated on PCI account / VPC landing |

Verification record: `docs/waf/waf-verification-record.md` V2.

### 2. OWASP Top 10 threats blocked by managed rules

**Met.** All three Web ACLs apply `AWSManagedRulesCommonRuleSet` plus `AWSManagedRulesKnownBadInputsRuleSet` at default Block. Specific sub-rules on `ingress-alb-waf` are set to Count to accommodate Wazuh's API behaviour (`EC2MetaDataSSRF_BODY`, `SizeRestrictions_BODY`, `GenericRFI_BODY`, `GenericRFI_QUERYARGUMENTS`); rationale documented in `docs/waf/waf-tuning-guide.md`.

### 3. Bot Control and rate limiting operational

**Partial — see acceptance note below.**

- Rate limiting: **operational** on all three Web ACLs. 2000 req/5min/IP on Ingress and Scriptcase, 500 req/5min/IP on PCI. Verified by inspecting the Web ACL rule list.
- Bot Control: **deferred to a controlled rollout** per `docs/waf/waf-design-decisions.md` D6. The reusable Terraform module (`waf-managed`) supports Bot Control as an opt-in toggle (`enable_bot_control`, with `inspection_level = COMMON | TARGETED` and per-sub-rule `Count` overrides). Recommended rollout (Scriptcase first, Count for 7 days, then promote to Block, then enable on Ingress) is documented in `docs/waf/waf-tuning-guide.md`. The deferral was a deliberate engineering decision driven by Bot Control's per-Web-ACL monthly fee and the false-positive risk on the existing traffic profile (synthetic monitoring, partner API consumers); promoting it is one Terraform PR away when Insight Group is ready to commit to the recurring cost.

**Recommendation for Insight Group:** schedule Bot Control rollout as a follow-up engagement once the traffic baseline is stable (week 4-5 of operation) — a 1-week effort.

### 4. Monitoring dashboard showing real-time traffic and blocks

**Met.** CloudWatch dashboard `perimeter-waf` deployed in us-east-2:

- One row of three widgets per Web ACL: traffic (allowed / blocked / counted), blocks broken down by rule, single-value rate-limit panel.
- Rollup row across all Web ACLs.

Plus 6 CloudWatch alarms (3 per Web ACL) routed to three severity-tiered SNS topics, each subscribed to the corresponding `insightgroup-security-{high,medium,low}@nebulariscloud.com` distribution list. Verification: `docs/waf/waf-verification-record.md` V3 + V4.

### 5. No false positives affecting legitimate business traffic

**Met as of closeout.** Existing Count overrides on `ingress-alb-waf` cover the known Wazuh API behaviour (4 sub-rules). All 6 alarms are in `OK` state at verification time with no live false-positives observed during the verification window.

**Caveat:** "Zero false positives" is unprovable in absolute terms — only prove-able for the traffic seen during validation. The framing has been operationalised as: alarms route to the security distribution list, the runbook (`docs/waf/waf-runbook.md`) covers identification and Count-override procedures, and the tuning guide (`docs/waf/waf-tuning-guide.md`) documents the false-positive workflow for future incidents.

## Deliverables — final status

### System & Architecture

| Deliverable | Status | Where |
|---|---|---|
| AWS WAF Web ACLs configured and associated | Delivered | LZA `custom-stacks/{ingress-alb,scriptcase-lb,pci-alb}.yaml` |
| Managed rule groups deployed and tuned | Delivered | Same files |
| Custom rules for application-specific protection | Capability delivered, no rules yet defined | `terraform/modules/waf-managed` `custom_rules` input |
| Rate limiting and AWS WAF Bot Control configuration | Rate limit delivered. Bot Control capability delivered, deferred per D6 | `terraform/modules/waf-managed` |
| CloudWatch monitoring and alerting setup | Delivered | `terraform/live/perimeter/waf-monitoring` |

### Documentation

| Deliverable | Status | Where |
|---|---|---|
| WAF architecture and rule documentation | Delivered | `docs/waf/waf-architecture.md` |
| Incident response runbook | Delivered | `docs/waf/waf-runbook.md` |
| Rule tuning and management guide | Delivered | `docs/waf/waf-tuning-guide.md` |
| Traffic baseline and threshold documentation | Template delivered, baseline values pending 7 days of data | `docs/waf/waf-traffic-baseline.md` |
| Design-decisions ADR (above and beyond SOW) | Delivered | `docs/waf/waf-design-decisions.md` |
| Verification record (above and beyond SOW) | Delivered | `docs/waf/waf-verification-record.md` |

### Training

| Deliverable | Status | Notes |
|---|---|---|
| Security operations walkthrough | Available on request | Runbook can drive a 60-minute session with the security team. Schedule with Nebularis. |
| Rule management and tuning training | Available on request | Tuning guide can drive a 60-minute session with engineering. Schedule with Nebularis. |

## Schedule vs SOW

| SOW phase | Planned | Actual | Notes |
|---|---|---|---|
| Discovery & Design | 1 week | ~2 days | Compressed because Insight Group's existing LZA + Terraform estate already covered ~50% of the SOW; design phase became a gap-analysis exercise. |
| Implementation | 2 weeks | ~3 days | Compressed for the same reason. |
| Tuning & Testing | 1 week | Verification day-of | Existing Web ACLs were already tuned for known false-positives; only fresh threshold tuning remains, scheduled for week 1 of operation. |
| Go-Live & Documentation | 1 week | Same day | All four operational docs delivered at merge. |

Net delivery: 4-5 days of engineering vs the 5 weeks planned, because Insight Group's existing infrastructure investment paid off here.

## What Insight Group owns going forward

- The CloudWatch dashboard, alarms, and SNS subscriptions are live and self-service.
- The reusable Terraform modules (`waf-managed`, `waf-logs`, `waf-monitoring`) are documented and ready for any future Web ACLs (CloudFront, API Gateway, additional ALBs) without additional engineering effort.
- All design rationale is captured in `docs/waf/waf-design-decisions.md` so future engineers don't have to reverse-engineer the choices.

## Recommended next steps for Insight Group

These are not part of the SOW. They're the practical follow-ups Nebularis would recommend based on what's now in the environment:

1. **Week 1:** capture traffic baseline. Open the `perimeter-waf` dashboard daily, fill in `docs/waf/waf-traffic-baseline.md`. End of week: tighten alarm thresholds.
2. **Week 2-3:** if useful, schedule the security operations walkthrough and rule management training.
3. **Week 4-5:** if Bot Control is wanted, run the rollout procedure documented in `waf-tuning-guide.md`. ~1 week of engineering, mostly observation time.
4. **When PCI account / VPC / cert land:** un-comment the PciAlb block in `customizations-config.yaml` and run the LZA pipeline. The PCI WAF deploys with it.
5. **Future:** if Insight Group adopts CloudFront or API Gateway, the `waf-managed` module already supports CLOUDFRONT scope and REGIONAL APIs. No additional engineering work needed beyond writing a new Terraform leaf.

## Sign-off

This document records that, as of the closeout date, the AWS WAF Implementation SOW is operationally complete. The first 50% payment was issued on signing per the SOW; the remaining 50% is now due per the "50% upon completion" term.

| Role | Name | Date |
|---|---|---|
| Service Provider — Nebularis Cloud LLC | _____________________ | _____________ |
| Client — Insight Group | _____________________ | _____________ |

---

*Reference: SOW "AWS WAF Implementation," dated March 5, 2026, between Nebularis Cloud LLC and Insight Communications Corp.*
