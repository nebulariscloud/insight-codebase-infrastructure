# CTI v7 migration — open items tracker

Single place for everything still outstanding. Nothing here is urgent as of
2026-08-07: the database is replicating at zero lag and serves no traffic yet.

**Live as of 2026-08-07:** four site VPNs up · `iccmaindb` replicating at
`Seconds_Behind_Master: 0` · DB security group carrying the 19 VPN site CIDRs
(PR #55) · osTicket running in shared-prod behind a dedicated Perimeter ALB
(PR #56). The two things with a deadline attached are **B6** (`read_only` must be
flipped or apps cannot write after cutover) and **G6** (an exposed DB password).

**Status legend:** ☐ not started · ◐ in progress · ✅ done · ⛔ blocked on someone else

**How the IDs work.** Every row has an ID like `B6` or `G11` — the letter is the
section below, the number is the row. They exist so a specific item can be referenced
in a PR description, a commit message or a conversation without restating it. Sections:
**A** blocked on the client or a vendor · **B** pre-cutover work that is ours ·
**C** waiting on an LZA config-zip + pipeline run · **D** reference data (the DB
security group CIDRs) · **E** cleanup, ordered because parts of it are load-bearing ·
**F** the cutover sequence · **G** osTicket.

---

## A. Blocked on the client / provider

| # | Item | Status | Notes |
|---|---|---|---|
| A1 | **Full IP inventory for all four sites** | ⛔ | We only learned about Kennedy's `10.12.x` incidentally. Need the complete map before finalising DB subnet placement (see B1). Asked; no answer yet. |
| A2 | **Kennedy `10.12.x` (Azure) resolution** | ⛔ | Their local Azure range collides with our shared-prod VPC `10.12.0.0/16`. Options: (a) they add static routes for our narrow `/26`s — wins on longest-prefix, simplest; (b) destination-NAT + policy route on their FortiGate; (c) we move the DB (see B1). Need to know whether Azure *occupies* addresses inside `10.12.0.64/26` or `10.12.0.128/26`. |
| A3 | **Aheeva RLM licence for CTI v7** | ⛔ | Vendor must reissue for hostid `02417393bdd5` and allowlist EIP `3.16.53.180` on TCP 5053/50555. Asterisk will not start until licensed. Start order once licensed: `service aheevalicenseserver start` → `service aheevacti start`. |
| A4 | **Separate reporting MySQL server — migrate or not?** | ⛔ | Own box, ~13 reporting consumers, transactional, independent of `iccmaindb`. Our scoping decision to drive with them. |
| A5 | **Luis Emerson `181.32.201.218`** | ⛔ | Confirm whether this still needs DB access. |

---

## B. Before cutover (ours to do)

| # | Item | Status | Notes |
|---|---|---|---|
| B1 | **Finalise DB subnet placement** | ☐ | Data subnets `10.12.0.64/26` + `10.12.0.128/26` collide with Kennedy's Azure range. **Free to move while the DB serves no traffic** — a brief interruption to something nobody queries, then re-run `mysql.rds_start_replication`. Fallback is the app subnets (`10.12.1.0/24` / `10.12.2.0/24`, two AZs so the multi-AZ subnet group still works) or a new secondary VPC CIDR at `10.13.0.0/16` (free inside our IPAM prod pool `10.12.0.0/14`, definitively outside their space). Depends on A1/A2. |
| B2 | **Add VPN client CIDRs to the DB security group** | ✅ | **PR #55 merged and applied 2026-08-07** (CI run `31213382224`, apply success). `vpn_client_cidrs` + the `mysql_vpn` ingress rule carry the 19 CIDRs from section D. Plan was 19 add / 1 change / 0 destroy; the DB instance was untouched. Worth confirming replication survived: `SHOW SLAVE STATUS\G` should still read `Seconds_Behind_Master: 0` (the replica SQL thread is exempt from `read_only`). |
| B6 | **⚠️ Flip `read_only` to `"0"` at cutover** | ☐ | The parameter group now sets `read_only = "1"` as a replica guard, so accidental writes are rejected instead of silently diverging from the source. **Applications cannot write until this is flipped.** Change `read_only = "0"` in `terraform.tfvars` and apply, as part of the cutover sequence (section F step 4). |
| B3 | **Repoint app connection strings** | ☐ | WS Aheeva + both webapps currently point at the **source** RDS. At cutover they change **hostname only** — credentials came across in the snapshot. New endpoint: `iccmaindb.cdu4e8csygjq.us-east-2.rds.amazonaws.com`. |
| B4 | **MySQL 5.7 → 8.0 upgrade** | ☐ | Deliberately deferred. Migrate 5.7→5.7, upgrade separately once the account move is stable. Source is paying Extended Support (~$299/mo seen in the June bill). |
| B5 | **HTTPS / ACM cert for the webapps ALB** | ☐ | `webapps-alb` leaf is HTTP-only pending a cert; adding `certificate_arn` auto-switches it to HTTPS. Also needs real hostnames + DNS. |

---

## C. Pending LZA config-zip + pipeline runs

These are batched deliberately — each pipeline run is 25–40 minutes, so it is worth
accumulating a few. **All edits are already made in `aws-accelerator-config/`.**

| # | Item | File | Status |
|---|---|---|---|
| C1 | **Add `kms:CreateGrant`** to the TerraformExecution allow-policy | `iam-policies/terraform-execution-allow-policy.json` | ✅ edited 2026-08-12, awaiting push |
| C2 | **Durable SCP fix** — scope `GRNETSEC2EIPAssociate` deny to `arn:aws:ec2:*:*:elastic-ip/*` so an untagged ENI no longer trips it | `service-control-policies/lza-core-workloads-guardrails-1.json` | ✅ edited, awaiting push |
| C3 | **Add `ec2:ModifyInstanceMetadataOptions`** — without it, IMDSv2 cannot be toggled on an existing instance | `iam-policies/terraform-execution-allow-policy.json` | ✅ edited 2026-08-12, awaiting push |
| C4 | **Add `ec2:MonitorInstances` + `ec2:UnmonitorInstances`** — the original gap, worked around with `monitoring = false` on every leaf | `iam-policies/terraform-execution-allow-policy.json` | ✅ edited 2026-08-12, awaiting push |

**Policy size check after the C1/C3/C4 edits:** 4,298 characters excluding whitespace
against the 6,144 managed-policy limit, so 1,846 to spare. Worth re-checking on any
future addition — AWS excludes whitespace, so the raw file size (6,121 bytes) is
misleading and looks far closer to the limit than it is.

**Why C1 matters:** RDS needs `kms:CreateGrant` to use a customer CMK. The allow-policy
is an explicit allow-list and omits it, which is what caused the
`KMSKeyNotAccessibleFault` failures. The `iccmaindb` leaf works around it with an
explicit key policy on its own CMK, so nothing is broken — but **any future leaf
using a customer CMK will hit the same wall** until C1 lands.

**Why C3 matters:** it is currently impossible to change IMDSv2 enforcement on an
*existing* instance. `imdsv2_required` in `production/ws-aheeva` is parked at `false`
purely because of this — declaring `true` made the apply fail with
`UnauthorizedOperation ... ec2:ModifyInstanceMetadataOptions`, and a permanently red
leaf masks real failures. Note metadata options **can** be set at launch, since
`ec2:RunInstances` is allowed, so a replacement fixes it without C3. That is the plan
for `ws-aheeva`, but any leaf needing to harden a *running* instance is stuck.

**The pattern behind C1/C3/C4:** the allow-policy is an explicit allow-list, so every
gap surfaces as `UnauthorizedOperation` at apply time on something that looks obvious.
Three have been hit so far. When a plan fails this way, check the allow-policy before
suspecting an SCP — the message distinguishes them clearly: *"no identity-based policy
allows"* is an IAM gap, whereas an SCP says *"explicit deny in a service control
policy"*.

**Why C2 matters:** without it, every future CTI v7 instance replacement will fail to
re-associate its EIP (the workaround was manually tagging the ENI `Migrated=CTIv7`).

Procedure when you run it:
```bash
cd aws-accelerator-config
zip -rq ../aws-accelerator-config.zip . -x "*.DS_Store" -x "__MACOSX/*"
# upload to the LZA config S3 bucket, then CodePipeline → AWSAccelerator-Pipeline → Release change
```

---

## D. DB security group — the exact CIDRs to add (B2)

Currently `terraform/live/production/iccmaindb/terraform.tfvars` has only:
```hcl
app_client_cidrs = ["10.12.0.0/16"]   # internal shared-prod only
```

**Recommendation:** add a separate `vpn_client_cidrs` variable with its own ingress
rule rather than overloading `app_client_cidrs` — that variable is documented as
"app-tier subnets in shared-prod", and mixing on-prem ranges into it obscures intent.
Requires a small addition to `variables.tf` and `main.tf` alongside the existing
`aws_vpc_security_group_ingress_rule.mysql_app`.

### Liberty — peer `23.249.138.106`
- `172.16.10.0/24`

### Insight Kennedy (Puerto Rico HQ) — peer `64.89.2.105`
Native:
- `172.27.150.0/27`, `172.27.100.0/24`, `172.27.50.0/25`, `172.27.75.0/24`,
  `172.27.200.0/24`, `172.27.220.0/24`, `172.26.4.0/22`
- `192.168.100.0/24`, `192.168.20.128/29`, `192.168.70.0/26`

NAT (their `10.234.5.0/26` arrives as):
- `100.64.4.0/22`

### Insight RD (Republica Dominicana) — peer `190.166.239.186`
Native:
- `172.20.0.0/24`, `172.20.1.0/24`, `172.20.2.0/24`, `172.20.3.0/24`, `172.20.4.0/24`

NAT (their `10.234.3.0/24` + `10.234.4.0/24` arrive as):
- `100.64.0.0/22`

### Insight Zima (Colombia) — peer `181.207.82.178`
NAT only — all of Zima's LANs are `10.234.x`:
- `100.64.8.0/22`

**19 CIDRs total.** Never add the raw `10.234.x` ranges — they are unroutable here and
arrive translated.

> Optional consolidation: `100.64.0.0/20` covers all three NAT ranges in one rule.
> Kept separate above for per-site auditability in flow logs and rule descriptions.

---

## E. Cleanup — ORDER MATTERS

⚠️ **Do not remove E1 or E2 before cutover.** Both are load-bearing right now.

### E1. Source SG `sg-3003a540` — egress NAT EIPs ⚠️ AFTER CUTOVER ONLY
Replication currently flows through these. Removing them **breaks replication**.
```bash
# source account 254422596287, us-east-1 — ONLY after mysql.rds_stop_replication
aws ec2 revoke-security-group-ingress --region us-east-1 --group-id sg-3003a540 \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=3.151.88.5/32},{CidrIp=3.133.15.33/32}]"
```

### E2. `cti-v7-ddhelper` ⚠️ CURRENTLY THE DB JUMP HOST
`i-0a1b064b3ad88f87d` (`10.12.1.16`). Idle since ~2026-07-05 from the AMI `dd` work,
but now the only SSM path to the private DB (see `iccmaindb-replication-check.md`).
Delete **last**, or first confirm another SSM-managed instance in `10.12.0.0/16`
works — e.g. `i-07cb992b7d8af1913` (insight-ubuntu-dev) or
`i-0c68cd3d481769973` (insight-ubuntu-prod).

### E11. osTicket's IP-pinned leftovers ⚠️ AFTER CUTOVER ONLY
Once osTicket runs from `10.12.1.67` against the destination:
- Source SG `sg-3003a540` — drop `54.84.28.176/32` (description `osticket`).
- Source MySQL — drop `osticket_user@54.84.28.176` (and any other public-IP host row),
  leaving only the private-range grants. Same for the temporary `@10.12.1.16`
  (`ddhelper`) row added for testing under G11.

Both are load-bearing until the old box stops serving. Do not pre-emptively remove them.

### E3. Your admin `/32` on source SG `sg-3003a540`
Added for MySQL access during Part 1. Safe to remove once you no longer need a
direct client session to the source.

### E4. Snapshots
| Snapshot | Where | When to delete |
|---|---|---|
| `iccmaindb-migration` | source, us-east-1 | now — superseded |
| `iccmaindb-migration-cmk` | source, us-east-1 | now — superseded |
| `iccmaindb-dest` | Production, us-east-2 | now — superseded by `-dest-cmk` (wrong KMS key) |
| `iccmaindb-dest-cmk` | Production, us-east-2 | **keep until cutover** — rollback artifact |

### E5. Orphaned volumes (Production, us-east-2)
`vol-02b91a4975cbd3097`, `vol-093f3896e7b2781d9` — dead artifacts of the failed
destination-side `dd` attempt. Idle since ~2026-07-06. Safe to delete now.

### E6. Source-tenant `dd` scaffolding (254422596287, us-east-1)
- helper instance `i-07b9f51d2f3be9f54`
- IAM role + profile `cti-v7-dd-ssm-role` / `cti-v7-dd-ssm-profile`
- the throwaway SG created for that helper
- source work volumes + the snapshot chain from the `dd` (`snap-0bd0743488ad51bc2`, `snap-0d8abcb2137ef4614`)

### E7. Tainted AMI
`ami-07b69272c5caf9d33` (Production) — carries the delisted CentOS marketplace product
code. **Keep** `ami-0289fff8a491f450a` (the clean registered one actually in use).

### E8. `repl_user`
- On the **source**: drop after cutover, once replication is finished with.
- On the **destination**: a copy exists (it was created before the snapshot). Unused —
  nothing replicates out of the destination. Drop or leave.

### E9. Source binlog retention + storage autoscaling
- Retention was raised to 168h for the migration. Revert or leave, depending on whether
  the source is being decommissioned.
- If `--max-allocated-storage 150` was enabled on the source, remove it if it was
  migration-only.

### E10. Perimeter dead helper
`i-0a1b064b3ad88f87d` is covered in E2. Also confirm nothing else lingers from the
Wave 1 work.

---

## F. Cutover sequence (for reference)

1. Pause source writes (stop WS Aheeva ingest).
2. Confirm `Seconds_Behind_Master: 0` — see `iccmaindb-replication-check.md`.
3. `CALL mysql.rds_stop_replication;` on the destination.
4. **Set `read_only = "0"` in `terraform.tfvars` and apply** (B6) — until this is done
   the applications cannot write to the destination.
5. Repoint app connection strings — **hostname only** (B3).
6. Verify apps + reporting clients.
7. Then work section E.

Rollback: the source stays intact with 7-day backup retention. Nothing about this
migration is destructive to it until you explicitly decommission.

---

## G. osTicket (Lightsail → shared-prod)

Adjacent workstream, tracked here because osTicket writes to `iccmaindb` and so
shares the DB cutover. Both leaves are **live** — PR #56 merged and applied
2026-08-07 (CI run `31219424964`, both applies green).

| Thing | Value |
|---|---|
| Instance | `i-0982eda3e21b97e76`, `10.12.1.67`, `t3a.micro`, shared-prod-app-a |
| AMI | `ami-069893c2d380d4dfb` (Lightsail export → transfer CMK → LZA EBS key) |
| ALB | `osticket-alb-343594101.us-east-2.elb.amazonaws.com` (Perimeter, HTTP-only) |
| Target group | `osticket-alb-tg/2848e58cb9083f3a` |
| Hostname | `osticket.insightgrouppr.com` (DNS at Network Solutions, `ns47`/`ns48.worldnic.com`) |
| App DB | `osticket_db`, user `osticket_user`, currently pointed at the **source** RDS |
| Live Lightsail box | **`54.84.28.176`** — confirmed three ways (G4). `204.236.253.33` was never right. |
| `osticket_user` host rows | `@54.84.28.176` only — see G11 |

| # | Item | Status | Notes |
|---|---|---|---|
| G1 | **Fix the ACM cert hostname** | ◐ | PR #56 applied with `tickets.insightgrouppr.com`, which does not resolve. **PR #57** corrects it to `osticket.insightgrouppr.com` (lowercase — ACM normalises `domain_name`, so mixed case desyncs the `domain_validation_options` key). Expected plan: 1 add / 1 destroy, cert only. Safe now because the cert is `PENDING_VALIDATION` and `enable_https = false`. |
| G2 | **Add the ACM validation CNAME** | ☐ | Zone is external, so Terraform cannot create it — read the `acm_validation_records` output after PR #57 applies and add it at Network Solutions. Then poll `aws acm describe-certificate --region us-east-2 --certificate-arn <arn> --query 'Certificate.Status'` until `ISSUED`. |
| G3 | **Stage 2: `enable_https = true`** | ☐ | Follow-up PR once the cert is ISSUED. HTTPS listener attaches, HTTP starts 301-redirecting. |
| G4 | **Serving-IP question — CLOSED** | ✅ | **`54.84.28.176` is the live osTicket box.** Source SG `sg-3003a540` carries `54.84.28.176/32` with the description `osticket`, written by the client's own admin, and `204.236.253.33` is **not in the group at all**. That is the third independent confirmation, alongside the DNS A record and the `osticket_user@54.84.28.176` grant. `204.236.253.33` in our Lightsail inventory was simply wrong or long stale. No impact on the AMI provenance — we exported the right box. |
| G13 | **⚠️ Do not stop/start the Lightsail box before cutover** | ☐ | `54.84.28.176` is pinned in **two** places that would both break silently if it rotated: the source SG rule above, and the `osticket_user@54.84.28.176` grant. If the instance has no static IP, a reboot-with-stop rotates the address and takes the live helpdesk's database access down with it. Confirm which it is — `aws lightsail get-instance --region us-east-1 --instance-name osticket1 --query 'instance.isStaticIp'` — and if `false`, treat the box as do-not-touch until cutover. Low effort, and it removes a way for the migration window to be ruined by something unrelated. |
| G5 | **No SSM agent on the instance** | ☐ | Third migrated box with this problem (after CTI v7 and `webapps`). Install `amazon-ssm-agent` inside the OS. **This now gates G11** — `ost-config.php` cannot be edited without a shell. Consider adding the agent to `user_data` in the `ec2-migrated` module so future migrated boxes arrive manageable; that is a module change, so it fans plans out across every live leaf. |
| G6 | **⚠️ Rotate `osticket_user`'s DB password — at cutover, not now** | ☐ | It was pasted into a chat session, so it must change. **Deliberately deferred to the cutover window.** The account is scoped to a single host (`54.84.28.176`), so exercising the password requires already controlling the live Lightsail box — which caps the practical risk. Rotating now would break the **live** osTicket the instant it takes effect, because `include/ost-config.php` on the Lightsail box carries the old value. Do it in one coordinated pass: `ALTER USER` every host row on the **source** (the destination is a read-only replica, so the change replicates down), then update `ost-config.php` on the migrated box. Host scoping is a mitigation, not a substitute for a secret being secret — do not let this slide past cutover. |
| G7 | **Prove the osTicket data replicated** | ☐ | Zero-risk and available right now as the master user, no grant changes needed: `mysql -h iccmaindb.cdu4e8csygjq.us-east-2.rds.amazonaws.com -u iccawsuser -p -e "SELECT COUNT(*) FROM osticket_db.ost_ticket; SELECT MAX(created) FROM osticket_db.ost_ticket;"` and the same against the source (`iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com`). Matching counts prove schema + data fidelity. |
| G11 | **Add the missing `osticket_user` host grants — hard cutover prerequisite** | ☐ | Not cleanup. The grant is **IP-pinned**, and at cutover osTicket's source address becomes `10.12.1.67`. Repoint `DBHOST` without this and the app fails with `Access denied` while every other piece is correct. `osticket_user` exists only as `@54.84.28.176`, so it cannot authenticate from `10.12.1.16` (ddhelper), from `10.12.1.67` (the migrated box, post-DB-cutover), or from the egress NAT EIPs `3.151.88.5` / `3.133.15.33` (the migrated box while it still points at the source DB). All three are needed. Run on the **SOURCE** and let it replicate — DCL is always statement-logged, and the replica SQL thread is exempt from `read_only`. Copy the existing credential rather than retyping it: `SELECT plugin, authentication_string FROM mysql.user WHERE user='osticket_user';` then `CREATE USER 'osticket_user'@'10.12.%' IDENTIFIED WITH 'mysql_native_password' AS '<hash>';` plus the grants from `SHOW GRANTS FOR 'osticket_user'@'54.84.28.176';`. Verify the rows appear on the destination within seconds. **Fallback if they do not replicate:** the destination cannot be written to while `read_only = "1"`, so the test waits for cutover (B6) rather than flipping the guard early. |
| G12 | **⚠️ Do not let both osTicket instances process mail** | ☐ | Once G11 lands, the migrated box can reach the **live source** DB. If its mail-fetch cron is enabled at the same time as the Lightsail box's, both poll the same mailbox and write to the same database — duplicate tickets, double auto-replies to real customers. **Disable cron on the migrated box** until the Lightsail box is stopped, and keep pre-cutover validation read-only. |
| G8 | **Confirm the app answers on :80** | ☐ | Target group `HealthyHostCount` on `osticket-alb-tg` is the quickest signal. Also confirm osTicket's mail cron still runs and outbound IMAP/SMTP works — the source IP changed, so any mail provider allowlisting the old Lightsail address needs the egress NAT EIPs `3.151.88.5` / `3.133.15.33` instead. |
| G9 | **Cleanup on `ddhelper`** | ☐ | `umount /mnt/ost`, detach + delete the temp volume and its snapshot, and detach + delete the orphaned 200 GB `nvme1n1` from the old `dd` work. Do this **after** G7 — the mount is how we read `ost-config.php`. |
| G10 | **Decommission the Lightsail box** | ☐ | Only after DNS has cut over and traffic is confirmed on the ALB. Keep the snapshot `osticket1-export-1` as the long-term artifact. |

### Source RDS 3306 ingress, as read on 2026-08-07

`sg-3003a540`, source tenant `254422596287`, us-east-1. Descriptions are the client's
own. This is the authoritative version of the inbound mapping — the 2026-07-14
screenshot-derived list should be read against it, not the other way round.

| CIDR | Description | Disposition |
|---|---|---|
| `64.89.2.20/32` | WNet Kennedy 1 | replaced by the Kennedy VPN |
| `64.89.2.105/32` | WNet Kennedy 2 | replaced by the Kennedy VPN |
| `154.64.223.34/32` | FiberX Kennedy | replaced by the Kennedy VPN |
| `186.150.204.2/32` | RD Contact Center | replaced by the RD VPN |
| `186.150.204.5/32` | RD New | replaced by the RD VPN |
| `181.207.82.178/32` | Col ZIMA | replaced by the Zima VPN |
| `23.249.138.106/32` | WNet data center | replaced by the Liberty VPN |
| `181.36.228.170/32` | RD Altice | **drop** — client marked *Eliminar* |
| `67.203.195.2/32` | TruNorth AAA BI | **drop** — client marked *Eliminar* |
| `190.60.92.154/32` | Col IFX | **drop** — client marked *Eliminar* |
| `181.204.67.42/32` | Col Tigo | **drop** — client marked *Eliminar* |
| `52.200.31.137/32` | lightsail n8n | internal after n8n migrates |
| `54.84.28.176/32` | osticket | internal after osTicket cuts over (E11) |
| `10.0.0.0/16` | Aheeva 3 v8.6 | other workstream |
| `3.151.88.5/32` | temp-replication-natgw-a | E1 — **load-bearing, replication path** |
| `3.133.15.33/32` | temp-replication-natgw-b | E1 — **load-bearing, replication path** |

Two things to note about this list:

- **The four *Eliminar* IPs are still open.** The client marked them for removal back
  on 2026-07-14 and they are still in the group. They do not carry over to the
  destination — its SG only has `app_client_cidrs` plus the VPN CIDRs in section D —
  so nothing needs doing for the migration. But the source stays exposed to them
  until either the group is tightened or the instance is decommissioned.
- **This query is not the full exposure picture.** It filters on `FromPort == 3306`
  exactly, so an all-traffic or port-range rule that happens to cover 3306 would not
  appear, and neither would SG-to-SG rules. `172.30.0.0/16` (the source VPC) was in
  the earlier mapping but is absent here, which is a hint that exactly that is
  happening. Worth a complete read before anyone claims the source is locked down:
  ```bash
  aws ec2 describe-security-groups --region us-east-1 --group-ids sg-3003a540 \
    --query 'SecurityGroups[0].IpPermissions' --output json | cat
  ```

**Ordering:** G7 (free, do it first) → G11 → G5 → G8 → G1 → G2 → G3 → DNS cutover →
G6 → G10. G9 waits until after G11/G7 because the `ddhelper` mount is how
`ost-config.php` gets read. G12 and G13 are standing constraints, not steps.

**Terraform comment debt:** `204.236.253.33` is still written into
`terraform/live/production/osticket/{main.tf,terraform.tfvars,README.md}` and
`terraform/live/perimeter/osticket-alb/{main.tf,terraform.tfvars,example.tfvars,README.md}`
as though it were the source's static IP. Comment-only, so it changes no
infrastructure — batch the correction into the stage-2 `enable_https = true` PR (G3)
rather than spending a plan cycle on it. PR #57 is deliberately left untouched: its
plan is already verified at 1 add / 1 destroy.

---

## See also

- `iccmaindb-replication-check.md` — how to connect and check replication health
- `iccmaindb-replication-miniguide.md` — the full Part 1 procedure as executed
- `cti-v7-wave2-runbook.md` — all of Wave 2 (Parts 1–8)
- `cti-v7-db-vpn-runbook.md` — the four site VPNs
- `.kiro/journal/2026-06-26-aheeva-cluster-migration-plan.md` — full working history
