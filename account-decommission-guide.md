# Account Park-and-Freeze Guide — Sandbox, Staging, QA, UAT

Audience: LZA operator for `thenew-aws-accelerator-config`.
Goal: drive `Sandbox`, `Staging`, `QA`, and `UAT` to **near-zero monthly cost** while keeping the AWS accounts alive and recoverable. No account closure.

> Read this end-to-end before touching anything. The order matters.

---

## 0. The strategy

You're going to:

1. **Drain** every billable workload resource in each account (this kills workload cost).
2. **Manually move** each account to the `Suspended` OU in the AWS Organizations console.
3. **Remove** the four account entries from `accounts-config.yaml` (LZA's validator requires this when the destination OU has `ignore: true`).
4. The existing `lza-suspended-guardrails` SCP applies via OU inheritance — locks the accounts so nothing can be recreated.
5. The `ignore: true` flag on the `Suspended` OU tells LZA to leave those accounts alone on every pipeline run.
6. (Optional) Manually disassociate org-wide security services from those accounts to drive cost to ~$0.

End state:

- Accounts still exist, still in your AWS Organization, still under your control.
- Monthly cost depends on how far you take it:
  - After steps 2–3 only: ~$30–40/account/mo (LZA security baseline keeps running).
  - After step 6 too: ~$0–1/account/mo.
- LZA pipeline is happy. No drift.
- Reactivation = manually move account back to its original OU + re-add to `accounts-config.yaml` + run pipeline.

What you are **not** doing:

- Not closing the AWS accounts.
- Not removing the `Workloads/Sandbox` or `Workloads/Test` OUs (they may stay empty, that's fine).

### Why this requires the manual OU move

LZA's validator enforces a hard rule: any account listed in `accounts-config.yaml` whose `organizationalUnit` is set to an `ignore: true` OU will fail validation with:

```
OU Suspended for account QA is ignored. Please remove the account from
accounts-config.yaml or target a different OU
```

The fix is to do both at once: move the account in the AWS Organizations console (so the SCP attaches via OU inheritance), and remove it from `accounts-config.yaml` (so the validator passes). LZA then ignores the account entirely on subsequent runs.

The accounts still belong to your AWS Organization. The Suspended OU's `ignore: true` flag is the supported "pause LZA for this account" switch — it doesn't affect the account ID, email, ownership, or org membership.

LZA's `security-config.yaml` does not support per-account exclusions for GuardDuty / Security Hub / Macie / Inspector. So the Suspended OU is the only LZA-native way to stop the security baseline from being re-enforced.

---

## 1. Pre-flight checklist

Before touching anything:

- [ ] You have **admin / break-glass access** to each account (Sandbox, Staging, QA, UAT).
- [ ] No production workload has cross-account dependencies into these four. Quick check: search your IaC outside LZA for the account IDs.
- [ ] You have a **change window** and ability to run the LZA pipeline.
- [ ] You've snapshotted or copied any data you might want later (databases, S3 contents) to a long-term account such as `LogArchive` or a dedicated archive account.
- [ ] No **Reserved Instances** or **Savings Plans** are owned by these accounts. If yes, transfer them or factor in the loss.

Optional:

- [ ] Tag remaining "do not delete" resources (if any) with a `KeepWhileSuspended` tag so future-you knows why they survived.

---

## 2. Quick sanity check (you said no workloads — verify in 5 min per account)

Skip the full inventory. Just confirm Cost Explorer shows what you expect: only LZA security baseline (KMS, Security Hub, Inspector, Config, GuardDuty/Macie). Anything outside that list is a workload you forgot about and needs to go before suspending.

Per account, in Cost Explorer:

1. Filter by linked account.
2. Group by Service, last 30 days.
3. Look for any of these (= forgotten workloads):
   - EC2-Instances, EC2-NatGateway, EC2-EBS, EC2-ElasticIP-Idle
   - RDS, Aurora, ElastiCache, OpenSearch
   - ELB, ApiGateway
   - S3 (significant storage)
   - Lambda Invocations, Lambda Duration

Expected services that are fine and will be handled by Section 6:

- KMS
- Security Hub (PaidComplianceCheck)
- Inspector (Lambda-Standard-Scanning, Lambda-Code-Scanning)
- Config (ConfigurationItemRecorded, ConfigRuleEvaluations)
- GuardDuty (PaidEventsAnalyzed)

If the list matches, jump straight to Section 4. If you see workload services, drain them first (use Section 3 below as reference).

---

## 3. Drain workloads (only if Section 2 found any)

If your sanity check came up clean, **skip this entire section**. Otherwise, delete in this order so dependents are gone before parents:

1. **Application layer**: ECS services, EKS deployments, Lambda functions you control, ASGs (set desired=0 first, then delete).
2. **Compute**: EC2 instances, EKS clusters, RDS / Aurora.
3. **Load balancers**: ALB / NLB / target groups.
4. **Networking add-ons**: NAT Gateways (release attached EIPs), VPC endpoints, TGW attachments.
5. **Storage**: EBS volumes, snapshots, S3 buckets (empty + delete; watch for versioned buckets).
6. **Backups**: AWS Backup recovery points, then vaults.
7. **CloudWatch**: log groups with long retention.

Do **not** delete:

- IAM roles created by LZA / Control Tower (`AWSControlTowerExecution`, `AWSAccelerator-*`). The Suspended SCP will protect them anyway, and you'll need them for reactivation.
- LZA-managed KMS keys at this stage. Section 6 handles those properly with a 30-day cancellable pending window.

After draining, wait 24–48 hours and re-check Cost Explorer.

---

## 4. Suspend the accounts (manual move + remove from config)

This is the LZA-managed lock-down step. There's a specific gotcha here — LZA's validator **rejects** any account in `accounts-config.yaml` that points at an `ignore: true` OU (like `Suspended`). The error looks like:

```
OU Suspended for account QA is ignored. Please remove the account from
accounts-config.yaml or target a different OU
```

So the supported flow is **two-part**: manually move the accounts in the AWS Organizations console, then remove them from `accounts-config.yaml`. LZA stops managing them, the Suspended SCP attaches via OU inheritance, and the validator is happy.

### 4a. Manually move the four accounts in AWS Organizations

Sign in to the **management account**:

1. AWS Organizations console → AWS accounts.
2. Select **Sandbox** → Actions → Move → choose **Suspended** OU → Move.
3. Repeat for **Staging**, **QA**, **UAT**.

The `Suspended-Guardrails` SCP is attached to the Suspended OU, so it applies to each account immediately via inheritance. You can verify by clicking the account → Policies tab.

### 4b. Edit `thenew-aws-accelerator-config/accounts-config.yaml`

**Remove** the four account blocks entirely (don't just change the OU — that fails validation). Final state of `workloadAccounts`:

```yaml
workloadAccounts:
  - name: SharedServices
    description: The SharedServices account
    email: insightgroup-shared@nebulariscloud.com
    organizationalUnit: Infrastructure
  - name: Network
    description: The Network account
    email: insightgroup-network@nebulariscloud.com
    organizationalUnit: Infrastructure
  - name: Perimeter
    description: The Perimeter account
    email: insightgroup-perimeter@nebulariscloud.com
    organizationalUnit: Infrastructure
  - name: Production
    description: Production workloads
    email: insightgroup-production@nebulariscloud.com
    organizationalUnit: Workloads/Prod
  - name: Development
    description: Code and feature development
    email: insightgroup-development@nebulariscloud.com
    organizationalUnit: Workloads/Dev
```

(Sandbox, Staging, QA, UAT entries removed.)

> The accounts still exist in AWS Organizations. You're just telling LZA "don't manage these anymore." The original `accounts-config.yaml` is preserved in your zip history if you ever need to copy them back for reactivation.

### 4c. Do not edit other config files

Leave `organization-config.yaml` and `global-config.yaml` alone. The `Workloads/Sandbox` and `Workloads/Test` OUs become empty after the manual move, but LZA is fine with empty managed OUs.

### 4d. Zip and upload

- Zip the contents of `thenew-aws-accelerator-config/` (not the folder itself) so the YAML files are at the root of the archive.
- Upload `aws-accelerator-config.zip` to the LZA config S3 bucket.
- CodePipeline → AWSAccelerator-Pipeline → Release change.

### 4e. Verify after pipeline success

- Pipeline goes green through `Prepare`, `Accounts`, `Organizations`.
- AWS Organizations console: Sandbox, Staging, QA, UAT all sit under `Suspended` (already true from step 4a; the pipeline just confirms LZA is no longer trying to manage them).
- Try launching a small EC2 with admin role in one of them. The `Suspended-Guardrails` SCP should deny it.
- Cost Explorer over the next 24–72 hours should show declining cost for those linked accounts.

---

## 5. Understand the residual cost

After suspension, **the LZA security baseline keeps running** even though the account is in `Suspended`. Empty workloads alone do not get you to $0. Real-world QA account billing example showed $37.42/month with no workloads at all.

Where the residual comes from per suspended account, per month:

| Service | Typical cost | Why it persists |
|---|---|---|
| KMS customer-managed keys | ~$1 per key per region (~$15–20 total) | LZA-created keys remain until manually scheduled for deletion |
| Security Hub paid compliance checks | ~$10 across enabled regions | FSBP + NIST 800-53 + CIS standards still evaluating |
| Inspector V2 (Lambda code/standard scanning) | ~$5–7 if Lambda was ever used | Delegated-admin org enrollment continues |
| AWS Config (configuration items + rule evaluations) | ~$1–3 | Recorder keeps running |
| GuardDuty / Macie / Access Analyzer | $1–5 | Org-wide enrollment continues |

**Expected total: $25–40/month per suspended account**, or roughly **$1,200–2,000/year for all four**.

If that's acceptable, you're done — stop here. This is the standard "park" tier and what most teams ship.

If you want closer to **$0**, continue to Section 6 (hard-park).

---

## 6. Hard-park (optional) — driving residual to near zero

This section is **only run after the Section 4 suspend pipeline has succeeded**. Doing it before is pointless because LZA will revert your changes on the next run. Once the account sits in `Suspended` (`ignore: true`), LZA stops touching it and these manual changes stick.

> Trade-off: the suspended accounts disappear from your security dashboards. If you reactivate them later, you have to re-enroll them in each service. Document what you do here so reactivation is repeatable.

### 6a. Disassociate from delegated-admin security services

Sign in to the **Audit** account (your `delegatedAdminAccount`). For each of the four suspended accounts:

1. **Security Hub** (biggest saving, ~$10/mo)
   - Security Hub console → Settings → Accounts → select account → Actions → Disassociate.
   - Repeat in every region where Security Hub was enabled (regionAggregation aggregates findings, but enrollment is per region).

2. **GuardDuty** (~$1–5/mo depending on activity)
   - GuardDuty console → Accounts → select → Disassociate.
   - Repeat per region.

3. **Macie** (~$1/mo idle)
   - Macie console → Accounts → Disassociate.

4. **Amazon Inspector** (~$5–7/mo if Lambda scanning was active)
   - Inspector console → Account management → select account → Disassociate.

5. **IAM Access Analyzer** (~$0.30/mo)
   - In the suspended account itself: IAM → Access Analyzer → delete the analyzer.

### 6b. Stop AWS Config in the suspended accounts

In each suspended account (sign in directly with admin credentials):

- Config console → Settings → toggle off the configuration recorder.
- Delete the delivery channel (or leave it — it's free without an active recorder).

Note: this works because LZA no longer manages the account. If your accounts are also Control Tower–enrolled, CT may try to re-enable Config drift detection. Test on one account first.

### 6c. Schedule KMS customer-managed keys for deletion

This is the largest single recurring cost (~$15–20/mo per account across 3 regions).

In each suspended account, in each region:

- KMS console → Customer managed keys.
- For LZA-created keys (typically tagged with `Accelerator`):
  - Confirm no service still references them. Check key policies and grants.
  - **Schedule key deletion** with a 30-day pending window (default 30 days, minimum 7).
- During the pending window the keys still bill, then drop to $0.

Do **not** delete keys that protect data you might want later (e.g., snapshots in `LogArchive`). Those keys typically live in `LogArchive`, not the suspended account, but verify.

### 6d. CloudWatch Logs cleanup

Any log groups in the suspended accounts continue to bill for storage at ~$0.03/GB/month. Either:

- Set retention to 1 day on each log group (data ages out within 24 hours), or
- Delete the log groups outright.

### 6e. Final state after hard-park

| Cost source | Before | After |
|---|---|---|
| KMS keys | $15–20 | $0 (after 30-day pending) |
| Security Hub | $10 | $0 |
| Inspector | $5–7 | $0 |
| GuardDuty / Macie | $1–5 | $0 |
| AWS Config | $1–3 | $0 |
| **Total per account** | **$30–40** | **<$1** |

You'll see a residual of pennies from things like cross-account CloudTrail (logs are written to `LogArchive` so cost lives there), tag policy evaluations, etc. Effectively $0.

---

## 7. Maintenance while parked

While the accounts are in `Suspended`:

- **Don't run pipelines that try to deploy into them.** LZA already skips them via `ignore: true`. Other tools (Terraform, CDK, custom scripts) need to be checked.
- **Periodically (quarterly) check Cost Explorer** for unexpected residual cost.
- **Don't rotate the root email** unless required. The email is bound to the account, not LZA.
- **Tags & metadata**: leaving tags untouched is fine. They cost nothing.

---

## 8. Reactivating an account later (e.g., 5 months from now)

After 5 months in Suspended + hard-park, the account state is:

- Account is in `Suspended` OU with `lza-suspended-guardrails` SCP attached.
- LZA-managed KMS keys are **permanently deleted** (the 30-day pending window has long expired).
- Security Hub, GuardDuty, Macie, Inspector are disassociated from the org.
- AWS Config recorder is stopped.
- IAM Control Tower / Accelerator roles (`AWSControlTowerExecution`, `AWSAccelerator-*`) are still present and untouched.
- Account ID, email, billing arrangement: unchanged.

### Step 1 — Move account out of Suspended in AWS Organizations console

Sign in to the management account:

1. AWS Organizations → AWS accounts → select the account (e.g., QA).
2. Actions → Move → choose the destination OU (e.g., `Workloads/Test`) → Move.

The Suspended SCP detaches automatically; the workload SCPs attached to the destination OU take effect via inheritance.

### Step 2 — Re-add the account to `accounts-config.yaml`

Add the account block back into `workloadAccounts`. Use the same name, description, and email as before:

```yaml
  - name: QA
    description: Quality assurance and integration testing
    email: insightgroup-qa@nebulariscloud.com
    organizationalUnit: Workloads/Test
```

Original OUs for reference:
- `Sandbox` → `Workloads/Sandbox`
- `Staging` → `Workloads/Test`
- `QA` → `Workloads/Test`
- `UAT` → `Workloads/Test`

> Tip: keep a copy of the pre-suspension `accounts-config.yaml` somewhere (your git history or an `aws-accelerator-config-pre-suspension.zip` snapshot) so future-you can copy these blocks verbatim.

### Step 3 — Zip, upload, run the LZA pipeline (1–2 hours, mostly hands-off)

What LZA does automatically when the account re-appears in `accounts-config.yaml` and is in a managed OU:

- Removes the `Suspended-Guardrails` SCP.
- Re-attaches workload SCPs (`Core-Guardrails-1/2`, `Core-Workloads-Guardrails-1`, or `Core-Sandbox-Guardrails-1` for Sandbox).
- Re-attaches the declarative VPC block public access policy.
- Re-attaches org tag policy, S3 tag policy, backup policy.
- **Recreates LZA-managed KMS keys** with the same names but new key IDs.
- Re-deploys the ~25 AWS Config rules.
- Re-enables the AWS Config recorder and delivery channel.
- Re-deploys SSM documents and remediation roles.

What LZA does **not** do automatically:

- Does not re-invite the account into the org-wide security services (Security Hub, GuardDuty, Macie, Inspector). You have to do this manually because LZA doesn't track that you previously disassociated.

### Step 4 — Re-enroll in security services from the Audit account (~10 min)

Sign in to the **Audit** account (delegated admin):

1. **Security Hub** → Settings → Accounts → Add account → enter account ID → invite. The account auto-accepts because it's in the same AWS Organization.
2. **GuardDuty** → Accounts → Add account → invite.
3. **Macie** → Accounts → Add account → invite.
4. **Inspector** → Account management → Add member → invite.

Tip: enable "auto-enable for new accounts" in each delegated admin console once you're back in steady state, so future reactivations don't need this step.

### Step 5 — Recreate IAM Access Analyzer (~1 min)

In the reactivated account: IAM → Access Analyzer → Create analyzer → Account analyzer with default settings.

### Step 6 — Verify and provision

- Within ~24 hours, Cost Explorer for the account should resume showing the ~$37/month LZA security baseline.
- Confirm in AWS Organizations console that the account now has the correct workload SCPs attached (via inheritance from the destination OU).
- The account is ready to receive workloads: VPCs, EC2, applications, etc.

### What survives the round trip

| Item | State |
|---|---|
| Account ID, email, billing | ✅ unchanged |
| IAM roles, users, permission sets | ✅ unchanged |
| IAM Identity Center / SSO assignments | ✅ unchanged |
| CloudTrail history (in LogArchive) | ✅ retained |
| Tags and account metadata | ✅ unchanged |
| Service quotas | ✅ unchanged |
| LZA KMS key IDs | ❌ new IDs (same names) |
| AWS Config recorded history | ❌ starts fresh |
| Security Hub findings history | ❌ starts fresh |

For empty accounts being reactivated, none of the "lost" items matter. You effectively get a clean slate with the same account ID.

### Total reactivation time

| Phase | Duration |
|---|---|
| Manual OU move in console | 1 min |
| Edit YAML + zip + upload | 5 min |
| LZA pipeline run | 1–2 hours, mostly waiting |
| Re-invite in 4 security services | ~10 min |
| Recreate Access Analyzer | ~1 min |
| **Total active time** | **~20 min**, plus pipeline wait |

### Edge case — quarantineNewAccounts

Your config has `quarantineNewAccounts.enable: true`. That SCP is meant for **brand-new** accounts entering the org, not OU moves. Moving from Suspended back to Workloads/Test should not trigger quarantine. After Step 2 pipeline completes, verify in the AWS Organizations console that the account has the workload SCPs attached (not `Quarantine-New-Object`). If you see quarantine, manually move the account back through the OU change in the console — the next LZA run will clean it up.

---

## 9. Rollback playbook

If step 4 (the suspend pipeline run) goes wrong:

- Move the four accounts back to their original OUs in AWS Organizations console (reverse of step 4a).
- Re-add the four account blocks to `accounts-config.yaml` (you can copy from your previous zip or git history).
- Zip and re-upload, run the pipeline. The `Suspended-Guardrails` SCP detaches via OU inheritance and the workload SCPs reattach.
- Resources you already deleted (if any) are **gone** — only the SCP/OU state is reversible.

If you discover after step 4 that you actually need the resources back:

- Follow the full reactivation flow in Section 8.
- Recreate resources from snapshots / backups / IaC.

If Section 6 (hard-park) goes wrong before KMS keys are permanently deleted:

- Cancel the key deletion within the pending window.
- Re-associate the account in each security service from Audit.

---

## 10. Files you will touch

| Step | File | What changes |
|---|---|---|
| 4a | (no config file) | Manual move of 4 accounts to Suspended OU in AWS Organizations console |
| 4b | `thenew-aws-accelerator-config/accounts-config.yaml` | Remove the 4 account entries |
| 6  | (no config file) | Manual console steps in Audit + each suspended account |

That is the **only** file you need to edit for park-and-freeze. Everything else stays as-is.

Files **not** touched (already verified clean of references to these accounts):

- `organization-config.yaml`
- `global-config.yaml`
- `network-config.yaml`
- `iam-config.yaml`
- `security-config.yaml`
- `customizations-config.yaml`
- `custom-stacks/*`

---

## 11. Estimated timeline

Since your accounts have no workloads, this collapses considerably:

| Phase | Duration |
|---|---|
| Section 2 sanity check | ~5 min per account |
| Section 4 config edit | 5 minutes |
| Suspend pipeline run | 1–2 hours |
| Section 6 hard-park (per account) | ~15 min in console |
| KMS pending window | 30 days passive |
| Verification | weekly Cost Explorer check |

Total active engineering time: **~2 hours of work**, then 30 days of passive waiting for KMS keys to actually delete.

---

## 12. Quick reference — final state

**After Section 4 only (park tier):**
- 4 accounts in `Suspended` OU.
- Workload resources removed (per Section 3).
- LZA security baseline still running.
- **Cost: ~$30–40/month per account, ~$1,500/year total.**
- Reactivation: edit one line in `accounts-config.yaml`, run the pipeline.

**After Section 4 + Section 6 (hard-park tier):**
- 4 accounts in `Suspended` OU.
- All workload resources removed.
- All LZA-managed security services disassociated.
- KMS keys scheduled for deletion.
- **Cost: ~$0–1/month per account, ~$50/year total.**
- Reactivation: edit `accounts-config.yaml` + re-enroll security services from Audit account.

---

## 13. References

- Landing Zone Accelerator on AWS — Config reference: https://awslabs.github.io/landing-zone-accelerator-on-aws/latest/user-guide/config/
- LZA — Account suspension and `ignore` flag: search "suspended" and "ignore" in the LZA implementation guide.
- AWS Organizations — Service Control Policies: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
