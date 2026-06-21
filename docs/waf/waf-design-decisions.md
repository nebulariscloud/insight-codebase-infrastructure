# WAF — design decisions

Companion to `waf-architecture.md`. The architecture doc describes **what** is deployed; this doc records **why** each design choice was made and what alternatives were considered.

Treat this as an architecture decision record (ADR). When future work materially changes one of these decisions, add an entry rather than rewriting in place.

## Context

The signed Statement of Work (March 2026) called for a clean-sheet AWS WAF deployment: design + deploy Web ACLs, managed rules, rate limiting, Bot Control, custom rules, integration with CloudFront / ALB, monitoring, logging, and an incident-response runbook. $8,500 fixed price.

When we sat down to plan the work, the existing repo state was:

- Three CFN-managed Web ACLs already deployed by LZA (`ingress-alb-waf`, `scriptcase-lb-waf`, plus `pci-alb-waf` template ready but un-deployed pending the PCI account / VPC).
- A Terraform module (`waf-managed`) covering the same managed-rule + rate-limit pattern, but not consumed by any live leaf.
- The ALB module (`alb`) had a `waf_web_acl_arn` association seam already in place.
- Security Hub, GuardDuty, AWS Config baselines org-wide (`security-config.yaml`).
- Central LZA log buckets in LogArchive (KMS-encrypted, lifecycle to GLACIER_IR after 365d).
- IAM `wafv2:*`, `cloudwatch:*`, `logs:*`, `s3:*`, `sns:*`, `kms:*` on the spoke `TerraformExecution` role.
- A CI/CD pipeline (`.github/workflows/terraform.yml`) that auto-detects new live leaves and runs `plan` + `apply` with OIDC into per-spoke `TerraformExecution`.

So the repo was already roughly 50-60% of the SOW. The rest was logging, monitoring, alarm wiring, and the **option** for Bot Control / geo / IPSets / custom rules.

There were also things in the SOW that don't apply to this environment: there are no CloudFront distributions and no API Gateways. Building infrastructure for surface area that doesn't exist would have been wasted work.

## Decisions

### D1 — Terraform over LZA / CloudFormation for new WAF work

**Decision:** All new WAF work (logging, monitoring, future Bot Control / geo / IPSet / custom rules) lands in `terraform/`. The three existing CFN-managed Web ACLs stay where they are for now.

**Alternatives considered:**

- Add the new pieces as more CFN custom-stacks under `aws-accelerator-config/custom-stacks/`. Same deployment path as the existing Web ACLs. Single tool to learn.
- Mixed: keep Web ACLs in CFN, put logging / monitoring in Terraform.

**Why Terraform:**

- LZA pipeline is ~30 minutes per change. WAF tuning is iterative — you'll do it dozens of times in the first month. The 30-minute round trip dominates the work.
- `terraform/README.md` already declares the boundary: LZA owns the platform, Terraform owns the apps. App WAFs are explicitly listed as Terraform's responsibility.
- The Terraform CI pipeline auto-detects new leaves under `terraform/live/`. No workflow edits required to plug in.
- IAM was already shaped for it (`wafv2:*` on `TerraformExecution`).

**Why we kept the existing Web ACLs in CFN for now:**

- They work, they're tuned for known false-positives (Wazuh API quirks), they're stable.
- Migration via `terraform import` is a real piece of work that should happen when day-2 tuning frequency justifies it — not now, when no tuning has been needed for months.
- `aws_wafv2_web_acl_logging_configuration` is a separate AWS resource from the Web ACL itself, so we can attach logging without touching the Web ACL or its CFN stack (see D4). This means we don't need to migrate to deliver the SOW.

**Trade-off:** Two ownership models for WAF in the same account. The `waf-architecture.md` doc explicitly calls this out so future engineers know which Web ACLs are which. The migration path is documented in the same place.

### D2 — Direct-to-S3 logging instead of Firehose or CloudWatch Logs

**Decision:** WAF logs ship straight to a Terraform-owned S3 bucket via the WAF service's built-in S3 destination support.

**Alternatives considered:**

- Kinesis Firehose → S3. AWS originally required Firehose for WAF logging; this is the default pattern in older docs.
- CloudWatch Logs (`/aws/waf/...` log group). Easier to grep with the console; supports metric filters.

**Why direct-to-S3:**

- **SCP friction.** `lza-core-guardrails-1` restricts `firehose:Create*/Delete*/Update*` to delivery streams whose ARN matches `arn:*:firehose:*:*:deliverystream/AWSAccelerator*`. A Terraform-owned Firehose stream named `waf-logs-*` would be denied. Workarounds (SCP exception, stream rename to `AWSAccelerator-waf-logs-*`) all require LZA pipeline runs.
- **Cost.** WAF emits one record per request. CloudWatch Logs ingestion is the most expensive of the three options — at any meaningful traffic volume it becomes the dominant line item.
- **Operational fit.** S3 + Athena is the same pattern LZA already uses for central logs. Engineers in this estate already know it.
- **Native support.** WAF has supported S3 as a first-class destination since 2021 — Firehose is no longer required.

**Trade-off:** Slightly higher latency to "log appears" (~5 minutes for the first object after traffic) compared to CloudWatch Logs (~1 minute). For incident response that's acceptable; for live debugging engineers should use `aws wafv2 get-sampled-requests`, which is real-time.

### D3 — Terraform-owned KMS CMK for WAF logs, not the LZA central-log key

**Decision:** The `waf-logs` module creates its own KMS CMK with a Terraform-owned key policy.

**Alternatives considered:**

- Reuse the LZA `aws-accelerator-s3-default-key` (the key encrypting LZA's central log bucket). One key, less proliferation.
- Use the AWS-managed `aws/s3` key. No CMK to manage at all.

**Why a Terraform-owned CMK:**

- **Ownership boundary.** `terraform/README.md` is explicit: Terraform reads LZA outputs but does not mutate LZA-owned resources. Reusing the LZA central-log key would require updating its key policy from a Terraform module, which crosses the boundary.
- **Auditability.** A dedicated key for WAF logs makes "who decrypted what, when" easy to read in CloudTrail. With a shared key the noise is much higher.
- **Blast radius.** Compromise of one key doesn't expose the rest of the central log estate.
- **Compliance.** Auditors prefer customer-managed encryption with rotation enabled (it is) and a single-purpose key policy.

**Why not the AWS-managed key:**

- No control over key rotation policy.
- No direct visibility in the key policy of who can use it.
- Can't be referenced cross-account if we ever centralize.

**Trade-off:** ~$1/month per CMK per region. Effectively zero.

### D4 — Attach logging via `aws_wafv2_web_acl_logging_configuration` without touching the Web ACL

**Decision:** The `waf-logs` Terraform leaf creates `aws_wafv2_web_acl_logging_configuration` resources pointing at the existing CFN-managed Web ACLs. The Web ACLs themselves are not modified.

**Alternatives considered:**

- Migrate the Web ACLs to Terraform first (`terraform import`), then add logging in the same module.
- Add a `LoggingConfiguration` block to the CFN templates and re-deploy via LZA.

**Why attach without modifying:**

- **It just works.** `aws_wafv2_web_acl_logging_configuration` is a separate AWS resource (not nested inside `aws_wafv2_web_acl`). Creating one does not modify the Web ACL or its CFN stack. CFN drift detection won't notice.
- **Same shape we already use.** `aws_wafv2_web_acl_association` (in the existing `alb` module) follows the same pattern: attach to a resource without owning it.
- **Decouples timelines.** Logging delivers immediately; the Web ACL migration question can be answered later on its own merits.

**Trade-off:** A future engineer reading the CFN template won't see the logging configuration. Mitigated by `waf-architecture.md` explicitly listing the ownership boundary.

### D5 — Rule evaluation order with allow-list at priority 0

**Decision:** When `allow_ip_cidrs` is non-empty, the IP allow-list rule sits at priority 0 (highest precedence). It short-circuits to Allow before any other rule runs — including the rate limit, including managed rule groups.

**Alternatives considered:**

- Allow-list at priority 0 with `Count` action (only flag, don't bypass).
- Allow-list at priority 0 with `Allow` action *but* exclude rate-limit (let rate-limit still apply).
- Allow-list deeper in the priority order (e.g., after IP reputation but before managed groups).

**Why bypass everything:**

- Allow-list semantics in WAF are "this source is fully trusted, skip all checks." If you want partial trust, use a custom rule, not the allow-list.
- Use cases for the allow-list are: vetted partners, internal monitoring, health-check sources, fast-restore during incident response. None of these should ever be rate-limited or fingerprint-checked by WAF.
- Putting allow at priority 0 is the only way it can override a Block from a higher-priority rule. WAF evaluation stops at the first terminal action (Allow / Block).

**Trade-off:** A misconfigured allow-list entry is the easiest way to silently let attack traffic through. Mitigated by:

- The IPSet must be edited via Terraform PR (CI plan is reviewed before apply).
- The runbook documents the risk explicitly.
- The dashboard surfaces `BlockedRequests` per rule, so a sudden drop in blocks tied to one rule (which would happen if a malicious IP got allowed through) is visible.

### D6 — Bot Control off by default

**Decision:** `enable_bot_control = false` by default in the `waf-managed` module.

**Alternatives considered:**

- Default on with `inspection_level = COMMON` (the cheaper tier).
- Default on with all sub-rules in Count mode.

**Why off:**

- Bot Control adds ~$10 per Web ACL per month plus per-request charges. With three Web ACLs that's ~$30/month minimum, plus per-request fees that scale with traffic. Not huge in absolute terms, but a non-zero ongoing fee that should be a conscious choice.
- Bot Control's `SignalAutomatedBrowser` and `CategoryHttpLibrary` sub-rules commonly fire on legitimate clients (synthetic monitoring, partner API consumers using `requests` / `curl`). Turning it on without a tuning window produces immediate false-positives.
- The SOW lists Bot Control as a deliverable but doesn't specify rollout cadence. The runbook in `waf-tuning-guide.md` lays out the right rollout: deploy in Count mode on Scriptcase first for a week, then promote, then enable on Ingress.

**Trade-off:** The SOW's Bot Control acceptance criterion isn't formally green until someone enables it. The setup work is done (toggle, override input, dashboard widget); promotion is one PR away. We're trading "checkbox green now" for "checkbox green when it's actually safe."

### D7 — Geo-blocking deferred (off by default, no values populated)

**Decision:** `geo_allow_country_codes` and `geo_block_country_codes` default to empty lists. No leaf populates them today.

**Alternatives considered:**

- Allow-list PR + US (the obvious geographic footprint based on the customer base).
- Block a small list of frequently-malicious source countries.

**Why neither yet:**

- Wrong geo gate is the easiest way to block a paying customer. Without a documented "which countries do we serve" decision from the business, applying any geo gate is guesswork.
- The customer base might already include partners or contractors outside the assumed geographic footprint. Blocking them produces support tickets, not security wins.
- Geo data has a non-trivial false-positive rate (mobile carriers, VPN edge IPs). A geographically-distributed VPN exit can land a real PR user in a "TR" geo bucket.

**Trade-off:** SOW lists geo as a capability but doesn't require deployment. Capability is built (module supports it, priority 2 in eval order), deployment is deferred until the business answer is crisp.

### D8 — Rate limit thresholds: 2000/5min/IP for prod, 500/5min/IP for PCI

**Decision:** The CFN templates already had these defaults. The Terraform module mirrors `2000` as its default. No change.

**Why these numbers:**

- 2000 / 5min = ~7 req/sec / IP. That's well above any single-user normal pattern, well above bot-driven scraping (which usually clusters at 10-50 req/sec on a single source), and below the threshold where WAF's rate-based rule starts being expensive (the rule evaluates every request, but the cost is per-request not per-IP).
- 500 / 5min for PCI = tighter because (a) PCI workloads see lower legitimate traffic and (b) credential-stuffing attempts against payment systems should hit the cap fast.

**When to tune:** `waf-tuning-guide.md` covers the procedure. The dashboard's RateLimit widget shows the current rate; if it never fires, the cap is too loose; if it fires multiple times a week with no real attack pressure, it's too tight.

### D9 — Three-tier severity: High / Medium / Low

**Decision:** Three SNS topics, three severity levels mapped to the existing `insightgroup-security-{high,medium,low}@nebulariscloud.com` distribution lists.

**Alternatives considered:**

- Single SNS topic, page-everyone-on-everything model.
- Two tiers (alarm / info).

**Why three:**

- The DLs already exist (defined in `replacements-config.yaml`). Reusing them keeps WAF alarm routing consistent with whatever else those DLs serve.
- High is reserved for "act now" — sustained rate-limit fires (the strongest "we're actively under attack" signal). Medium is "look at it within an hour." Low is informational / daily summary.
- Three-tier maps cleanly to most on-call rotations: page on High, ticket on Medium, ignore unless aggregating Low.

**Mapping:**

| Alarm | Tier | Why |
|---|---|---|
| `*-rate-limit-blocks` | High | Sustained DDoS / abuse signal. Requires real-time response. |
| `*-blocked-total` | Medium | Could be attack pressure or scanner noise; needs human judgment. |
| `*-common-ruleset-blocks` | Medium | Spike usually means a new attack pattern or a bad deploy. |

Low is reserved for future use (daily summary, capacity-planning alerts) — variable is in place, no alarm currently routes there.

### D10 — Generous initial alarm thresholds, narrow after baseline

**Decision:** Default thresholds (`blocked_requests_threshold=1000`, `rate_limit_block_threshold=200`, `common_rule_set_block_threshold=500`, all per 5-minute window) are intentionally loose.

**Why loose first:**

- Internet-scanner background traffic produces a non-zero floor of `BlockedRequests` even on idle workloads. Tight thresholds out of the gate would alarm-storm before any real signal exists.
- The dashboard captures the baseline empirically over the first week. `waf-traffic-baseline.md` is the place where those numbers get recorded and the thresholds get tightened.
- "Loose now, tight later" is one PR. "Tight now, loose later after operators get fatigued" is much harder to walk back culturally.

**Trade-off:** First week of alarms may miss low-volume attacks. Acceptable because (a) the dashboard catches them visually, (b) `get-sampled-requests` is always available for spot-check, and (c) the 7-day baseline will catch any sustained patterns.

### D11 — Logs bucket per region, named `aws-waf-logs-<account>-<region>`

**Decision:** One logs bucket per region in the account that owns the Web ACLs. Naming follows the LZA convention (`aws-accelerator-elb-access-logs-<account>-<region>` is the parallel).

**Alternatives considered:**

- Single bucket centralized in LogArchive, cross-account write.
- One bucket per Web ACL.

**Why per-region, per-account:**

- WAF requires the destination to be in the same region as the Web ACL. Cross-region delivery isn't supported.
- Cross-account write is supported but adds bucket-policy complexity. Today both Web ACLs are in the same account so this is a non-issue.
- Per-Web-ACL buckets are over-fragmented; the bucket name has no security boundary value, the WAF logs themselves are partitioned per Web ACL inside the bucket.

**Naming:** `aws-waf-logs-` is the WAF-required prefix. Account ID + region disambiguate the bucket globally, mirroring the LZA `aws-accelerator-elb-access-logs-<account>-<region>` convention.

### D12 — `custom_rules` covers byte-match and rate-with-scope-down only

**Decision:** The `waf-managed` module's `custom_rules` input handles two patterns: byte-match (block / allow / count / captcha / challenge a URI / header / query-string match) and rate-based with optional URI scope-down. More complex statements (logical AND/OR combinations, regex sets, JSON-body matches) require dropping a separate `aws_wafv2_web_acl_rule` next to the module — they're not in `custom_rules`.

**Why this scope:**

- The two supported shapes cover the 90% case in this estate: "block requests whose user-agent contains `<scanner>`," "rate-limit `/login` per IP."
- A fully generic rule input would either be a faithful but unergonomic copy of the WAF API schema, or an opinionated DSL we'd then have to maintain.
- For the rare complex case, dropping a literal `aws_wafv2_web_acl_rule` resource in the leaf is easier than learning an abstraction.

**When to extend:** If two leaves need the same complex pattern, lift it into the module. Don't pre-build for hypothetical patterns.

## What this leaves on the table

Honest list of things the design doesn't cover, and why:

- **CloudFront-scoped Web ACL.** Module supports `scope = "CLOUDFRONT"` with a `us-east-1` provider alias. Not deployed because no CloudFront distributions exist in this estate. Day-zero of a future CloudFront distribution: add a leaf with `scope = "CLOUDFRONT"`. Pattern documented in module README.
- **AWS Shield Advanced.** Out of scope. ~$3,000/month standalone subscription decision; needs business justification. The standard Shield (free) is on automatically for any AWS account.
- **AWS Network Firewall.** Explicitly removed from this LZA config (`network-config.yaml` line 1-4) for cost reasons (~$570/month). Not part of WAF scope anyway.
- **Route 53 Resolver DNS Firewall.** Different threat model (DNS-layer threats, malicious domain blocking), different control plane. Not in the SOW.
- **Athena workspace over WAF logs.** Mentioned in `waf-tuning-guide.md` and `waf-logs/README.md` as the standard analysis pattern. Not built — separate analytics engineering effort. The bucket is shaped for it.
- **Account Takeover Prevention (`AWSManagedRulesATPRuleSet`).** Designed for login surfaces. None of the current workloads have a public login surface that ATP would protect. If a customer-facing login endpoint lands in scope later, add it then.
- **PCI ALB deployment.** The `pci-alb.yaml` template is built and tuned, but the deployment block in `customizations-config.yaml` is commented out pending the PCI account / VPC / cert. When those land, the WAF for the PCI ALB ships with the rest of the PCI bring-up. No additional WAF design work needed.

## Changelog

| Date | Change | PR |
|---|---|---|
| 2026-06-21 | Initial design record. WAF SOW implementation merged. | feat/waf-sow-implementation |
