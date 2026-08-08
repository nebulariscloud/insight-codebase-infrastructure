# CTI v7 Cluster Migration Plan

End-to-end plan for migrating the **CTI v7 cluster** from the source tenant (`254422596287`, `us-east-1`) into the new tenant (`395516496764`, `us-east-2`, `shared-prod` account).

Four EC2 servers plus one RDS MySQL instance, all tied together via the RDS. Sequenced easy-first so cutover risk sits on the last wave, not the first.

> **This is a separate migration** from the Aheeva CTI v8.6 + DB Slave workstream (see `docs/07-Operations/aheeva-migration-questionnaire.md`). Same vendor name, different boxes, different RDS, different clients.

> **Delivery model:** every AWS resource in the new tenant is created via **Terraform** in this repo, applied by **GitHub Actions** on merge to `main`. No LZA `custom-stacks` templates, no `migrated-ec2.yaml`, no console-driven deploys. See `.kiro/steering/terraform-changes-via-github-pr.md` for the workflow rules.

---

## Cluster Inventory

| Role | Source | Talks to RDS? | Disk mutable? | Public-facing? | Migration wave |
|---|---|---|---|---|---|
| CTI v7 | EC2 (source tenant) | Indirect, via WS Aheeva | Likely no | TBD | Wave 2 |
| WS Aheeva | EC2 (source tenant) | Yes — writes daily client files | Yes (low volume) | Yes — clients push files in | Wave 2 |
| Webapps Server | EC2 behind old ELB | Yes (read) | No | Behind LB, ~95% internal | Wave 1 |
| Webapps PHP 7.3 | EC2 behind old ELB | Yes (read) | No | Behind LB, internal | Wave 1 |
| `iccmaindb` | RDS MySQL 5.7.44, `db.t3.small`, 50 GiB, MultiAZ | — | — | Publicly accessible today | Wave 2 |

Source EC2 instance IDs and sizes: **pending from client**.

---

## Architecture Summary

| Layer | Source | Destination |
|---|---|---|
| Account | `254422596287` | `395516496764` (`shared-prod`) |
| Region | `us-east-1` | `us-east-2` |
| RDS VPC | Default VPC `vpc-3be9b55d` | `AWSAccelerator-us-east-2-shared-prod` |
| RDS network exposure | Publicly accessible on 3306, 18 public IPs allowlisted directly | Private only, reachable from app-tier SGs over VPC routing |
| EC2 network exposure | Old-tenant ELBs / direct EIPs | New Terraform-managed ALB/NLB in perimeter, targeting private IPs over TGW |
| Egress | Direct via IGW | TGW → perimeter Egress VPC → NAT GW |
| Admin access | SSH from allowlisted IPs | SSM Session Manager or EC2 Instance Connect Endpoint |
| RDS encryption | `aws/rds` (AWS-managed, not shareable) | Customer-managed CMK owned by Terraform |
| MySQL version | 5.7.44 (Extended Support) | 5.7.44 initially (upgrade to 8.0 as separate exercise) |

---

## Delivery Model

Every AWS change lands via a PR in this repo. The workflow is enforced by `.github/workflows/terraform.yml` and gated by the `production` GitHub Environment.

- **Runtime resources** (EC2 instances, security groups, RDS, IAM, KMS, target groups, listener rules): a new Terraform leaf per workload under `terraform/live/production/` or `terraform/live/perimeter/`.
- **Modules already available in this repo:**
  - `terraform/modules/ec2-migrated` — canonical EC2 lift-and-shift shape. Used by `sftp-server` and will be reused for all four servers in this migration.
  - `terraform/modules/alb` — application load balancer for the perimeter ingress path.
  - `terraform/modules/nlb` — network load balancer, if any of these workloads need TCP-level exposure (unlikely for this cluster).
- **What we add per this migration:**
  - `terraform/live/production/cti-v7/` — CTI v7 EC2, SG, IAM (if custom).
  - `terraform/live/production/ws-aheeva/` — WS Aheeva EC2, SG, IAM. Additional EBS volume for the file inbox / working directory (mutable disk).
  - `terraform/live/production/webapps/` — Webapps Server EC2, SG.
  - `terraform/live/production/webapps-php73/` — Webapps PHP 7.3 EC2, SG.
  - `terraform/live/production/iccmaindb/` — RDS MySQL instance, subnet group, parameter group, security group, replication user secret in Secrets Manager, customer-managed CMK.
  - `terraform/live/perimeter/webapps-alb/` — target group + listener rule per webapp on the shared perimeter ingress ALB (or a dedicated internal ALB, per Wave 1 decision).
  - `terraform/live/perimeter/ws-aheeva-ingress/` — depends on the file-drop protocol answer. SFTP → sibling leaf like `sftp-nlb`. HTTPS → ALB target group. S3 PUT → nothing in perimeter, clients write directly.
- **One-time source-tenant helpers** (create a customer-managed CMK, re-encrypt the RDS snapshot, share to destination): these run in the source tenant which is **not** managed by this Terraform. They're one-shot AWS CLI commands executed by hand from an authorized session, documented in the cutover runbook.

**No local `terraform apply`.** All changes reach AWS through PR → CI plan → merge → CI apply.

---

## Why This Migration Is Shaped This Way

- **RDS-native cross-account read replicas are not supported for non-Aurora MySQL.** So the replication mechanic is: snapshot in source, re-encrypt with a shareable CMK, share cross-account, copy cross-region, restore, then set up external binlog replication from source → destination. Async under the hood, but with traffic paused at cutover, lag drops to zero within seconds.
- **The current RDS encryption key is `aws/rds`.** AWS-managed keys can't be shared cross-account. This adds one `copy-db-snapshot` step in the source tenant, re-encrypting with a purpose-built customer-managed CMK, before the snapshot can be shared.
- **The two static webapps go first (Wave 1).** Stateless from a disk standpoint, low-traffic, internal. Good place to prove the AMI-export → Terraform-leaf → target-group → DNS cutover before touching the box that ingests daily client files.
- **WS Aheeva goes last, alongside the RDS cutover (Wave 2).** Its failure stops daily client file ingestion. Its cutover coordinates directly with the RDS promotion.
- **CTI v7 is Wave 2 but low-risk.** It talks to RDS only via WS Aheeva, so it just needs to reach WS Aheeva on its new private IP after cutover.
- **We're not migrating the old ELBs.** New Terraform-managed target groups sit behind the perimeter ingress ALB in the new tenant. Consistent with the SFTP and Scriptcase patterns already in the repo.

---

## Prerequisites in the New Tenant (already in place)

- [x] `shared-prod` VPC and app-a / app-b subnets (LZA-managed)
- [x] TGW route from `shared-prod` to the perimeter Egress VPC for `0.0.0.0/0` (LZA-managed)
- [x] Perimeter ingress ALB (`terraform/modules/alb`; leaves that add target groups already merged for SFTP/Scriptcase patterns)
- [x] `terraform/modules/ec2-migrated` — the canonical migrated-EC2 module used across production leaves
- [x] Central SSM/SSMMessages/EC2Messages interface endpoints (LZA-managed)
- [x] `EC2-Default-SSM-Role` instance profile (LZA-managed, referenced by `ec2-migrated` module)
- [x] CI: `.github/workflows/terraform.yml` runs plan on PR, apply on merge (gated by `production` GitHub Environment)

## Prerequisites to Create Per-Migration

**In Terraform (via PRs):**

- [ ] `terraform/live/production/iccmaindb/` — customer-managed CMK for destination RDS, subnet group, parameter group matching `enabletriggers-5-7` shape (with `binlog_format=ROW`), security group, RDS instance, Secrets Manager entry for replication user
- [ ] `terraform/live/production/{cti-v7,ws-aheeva,webapps,webapps-php73}/` — one leaf per server using `ec2-migrated`
- [ ] `terraform/live/perimeter/webapps-alb/` — target group + listener rule per webapp
- [ ] `terraform/live/perimeter/ws-aheeva-ingress/` — form depends on file-drop protocol (SFTP-NLB / HTTPS-ALB / S3)

**Out of band, in the source tenant (one-time AWS CLI, not Terraform):**

- [ ] Customer-managed CMK for re-encrypting the RDS snapshot before sharing
- [ ] `binlog_format` = `ROW` in parameter group `enabletriggers-5-7` (`aws rds modify-db-parameter-group ...`, dynamic, no reboot)
- [ ] `binlog retention hours` = 168 via `CALL mysql.rds_set_configuration(...)` if the current value is lower
- [ ] Temporary ingress on `sg-3003a540` for the destination NAT GW EIPs on port 3306 (replication catch-up window)

---

## Wave 1 — Webapps Server + Webapps PHP 7.3

Both stateless-from-disk and internal. Goal: prove the machinery end-to-end.

### Source-side (one-time, per server, AWS CLI in source tenant)

1. Snapshot the source EBS root volume.
2. Create an AMI from the snapshot.
3. Share the AMI + snapshot with `395516496764`.
4. If the source AMI is encrypted with `aws/ebs`: re-encrypt with a customer-managed CMK in the source tenant first, then share.

### Destination-side (via PRs)

For each of the two webapps, one PR:

1. Copy AMI to `us-east-2` in `shared-prod`, re-encrypted with the LZA-managed destination CMK (**out of band, AWS CLI**, captured in the leaf's README as a prerequisite step).
2. Open a PR adding `terraform/live/production/webapps/` (or `webapps-php73/`) modeled on `sftp-server/`:
   - `module "ec2_migrated"` with the copied AMI ID.
   - Per-app SG with the app port open from the perimeter ingress VPC CIDR.
   - Optional additional EBS volumes if the source had them.
   - Outputs: `private_ip`, `instance_id`, `security_group_id`.
3. Open a PR adding `terraform/live/perimeter/webapps-alb/` (or extend an existing perimeter ingress leaf):
   - Target group per app.
   - `register_targets` with the `private_ip` output from step 2 (looked up via remote state or explicit tfvars, whichever the repo already uses — see `sftp-nlb` for the pattern).
   - Listener rule with host-header.

### Cutover per webapp

- Connection strings unchanged. Both webapps continue pointing at the source RDS endpoint over the public internet during Wave 1 (source is `PubliclyAccessible=True`).
- DNS record for the app hostname repointed at the new ingress ALB, 60s TTL.
- Watch target group health, then the old ELB traffic drops to zero.

### Rollback

- Terraform state has the new resources; the old ELB is still up and unchanged. Point DNS back at the old ELB name.

---

## Wave 2 — CTI v7, WS Aheeva, and RDS `iccmaindb`

### Pre-cutover (T-7 days to T-1 day)

**Source-tenant work (AWS CLI, one-shot):**

- `aws rds modify-db-parameter-group ...` to flip `binlog_format` to `ROW`.
- `mysql -h iccmaindb...` + `CALL mysql.rds_set_configuration('binlog retention hours', 168);` if the current value is lower.
- Create a customer-managed CMK in the source tenant; grant `395516496764` `Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey/CreateGrant`.
- Take a fresh manual snapshot of `iccmaindb`.
- `aws rds copy-db-snapshot` re-encrypting with the new CMK.
- Share the re-encrypted snapshot with `395516496764`.

**Destination-tenant work (PR):**

- Open a PR adding `terraform/live/production/iccmaindb/`:
  - Customer-managed CMK owned by this leaf.
  - Subnet group across the `shared-prod` data subnets.
  - Parameter group cloned from source with `binlog_format=ROW`, `log_bin_trust_function_creators=1`.
  - Security group scoped to the app-tier SGs (CTI v7, WS Aheeva, both webapps).
  - `aws_db_instance` **restored from the shared snapshot** via `snapshot_identifier`, re-encrypted with the destination CMK.
  - Secrets Manager entry for the future replication user credentials.
- Merge and let CI apply.
- **After apply:**
  - Manually create the MySQL replication user on the source (`GRANT REPLICATION SLAVE ...`).
  - Capture the binlog file + position from the shared snapshot's MySQL error log.
  - On the destination, run `CALL mysql.rds_set_external_master(...)` + `CALL mysql.rds_start_replication;`.
  - Monitor `SHOW SLAVE STATUS\G` until `Seconds_Behind_Master = 0`.

**EC2 baseline AMIs (out of band, source tenant):**

- Snapshot CTI v7. Snapshot WS Aheeva (baseline only — final snapshot happens at cutover because the disk is mutable). Share both, copy to `us-east-2`, re-encrypt.

### Cutover window (~30 min DB, ~1-2 hrs including WS Aheeva)

Time-ordered. Each Terraform step is a **pre-merged PR** that CI applies during the window on manual `workflow_dispatch`, or a change is merged live if you prefer.

1. Announce start; tell file-drop clients to pause sends.
2. Drain WS Aheeva's inbound queue on source; confirm all pending files are processed to RDS.
3. Stop writes: WS Aheeva down on source, Wave 1 webapps switched to read-only or briefly down.
4. Wait for destination replica lag = 0.
5. On destination RDS: `CALL mysql.rds_stop_replication;`. Take the manual final snapshot for rollback insurance.
6. Take the final source-side WS Aheeva EBS snapshot, create AMI, share + copy to `us-east-2`.
7. Update `terraform/live/production/ws-aheeva/` PR with the final AMI ID; merge; CI applies. The leaf brings up WS Aheeva pointing at the new RDS endpoint (via tfvars).
8. Merge the pre-staged CTI v7 leaf update if there's an AMI ID pending; CI applies. Confirm CTI v7 reaches WS Aheeva on its new private IP.
9. Update Wave 1 webapps' connection strings to the new RDS endpoint. Depending on where the connection string lives:
   - If it's in tfvars → PR to update, merge, CI applies (Terraform will trigger an instance user-data change or a config file bake, depending on how the leaf is wired).
   - If it's inside the instance filesystem → SSM Run Command to edit and restart the app, out-of-band. Note: this is stateful drift and should be avoided; prefer tfvars.
10. DNS cutover for the WS Aheeva file-drop endpoint.
11. Ask file-drop clients to resume sends. Verify a test file lands and processes end-to-end.

### Post-cutover (T+0 to T+7)

- Source RDS stays alive, read-only, as rollback. No writes.
- Source WS Aheeva stopped-but-recoverable in case a file needs replay.
- Monitor: file arrival rate, WS Aheeva processing latency, RDS error/slow-query logs.
- T+7 (or a later date per rollback preference): open a decommission PR that removes the source-tenant resources. Since the source tenant isn't Terraform-managed, decommission is manual AWS CLI.

---

## Info Needed From the Client

Blocking:

- MySQL admin access on `iccmaindb` to run `CALL mysql.rds_show_configuration;` and optionally bump binlog retention.
- Source EC2 instance IDs and sizing for all four servers.
- WS Aheeva file-drop protocol (SFTP / HTTPS / S3 / other) and client sender list.

Decisions:

- `binlog_format` flip timing (today vs maintenance window).
- MySQL 5.7-to-5.7 vs 5.7-to-8.0 at cutover.
- Whether CTI v7 is user-facing (needs DNS + ALB rule) or purely internal.
- Fate of the 18 public-IP entries on `sg-3003a540` — active/stale mapping.

Scheduling:

- Maintenance window (day + time).
- Blackout periods to avoid.
- Rollback window duration (default 7 days).

---

## Migration Order at a Glance

1. Client answers blocking questions and locks decisions.
2. Wave 1 — PR per webapp for `terraform/live/production/webapps*/` + perimeter leaf. Wave 1 apps still point at source RDS.
3. Pre-cutover prep — RDS `iccmaindb` leaf merged and replicating; source-tenant parameter group + binlog changes done; CTI v7 baseline AMI ready.
4. Wave 2 cutover window — RDS promoted on destination, WS Aheeva leaf merged with final AMI, CTI v7 leaf merged, Wave 1 apps repointed to new RDS.
5. Post-cutover soak, then source decommission.

---

## Reference Docs

- `.kiro/steering/terraform-changes-via-github-pr.md` — the workflow rules every change in this plan follows
- `terraform/modules/ec2-migrated/README.md` — module used for all four EC2 leaves
- `terraform/live/production/sftp-server/` — canonical production leaf pattern to mirror
- `terraform/live/perimeter/sftp-nlb/` — canonical pattern for the perimeter ingress + private-IP-target hand-off (relevant if WS Aheeva ends up needing an NLB for SFTP)
- `snapshot-ami-migration-guide.md` — source-tenant cross-account snapshot share + cross-region copy + KMS re-encrypt (still relevant; the source-tenant side of this migration follows it)
- `docs/07-Operations/aheeva-migration-questionnaire.md` — questionnaire for the **separate** Aheeva CTI v8.6 migration

---

## Open TODOs

- [ ] **HTTPS / ACM certificate for the webapps ALB.** The dedicated cluster ALB (`terraform/live/perimeter/webapps-alb/`) is applied **HTTP-only** for now because no ACM certificate exists yet. Host-header routing works over HTTP (both apps reachable), but traffic is unencrypted at the edge. When a cert is available: request/import an ACM cert in **us-east-2, Perimeter account (`713939170920`)** covering both webapp hostnames, set `certificate_arn` in the leaf's `terraform.tfvars`, and re-apply. The leaf auto-switches: HTTP redirects to HTTPS and the host-header rules move to the HTTPS listener. No structural change needed — just the cert + re-apply.
- [ ] **DNS records** for the two webapp hostnames → the webapps ALB `alb_dns_name` (A-alias). Set the real hostnames in `webapps_server_host` / `webapps_php73_host` first.
- [ ] **CTI v7 Aheeva license** — reissue against RLM hostid `02417393bdd5` + allowlist EIP `3.16.53.180` (vendor round-trip; box is parked until then).
- [x] **RDS `iccmaindb` (Wave 2)** — leaf built (`terraform/live/production/iccmaindb/`): CMK + subnet group + parameter group (ROW + trust-function-creators) + private SG + restore-from-snapshot instance. TODO before apply: fill `snapshot_identifier` (dest snapshot) + `db_subnet_ids` (data-a/b); source binlog prep; post-apply set up `mysql.rds_set_external_master` replication.
- [x] **WS Aheeva (Wave 2)** — leaf built (`terraform/live/production/ws-aheeva/`) + FTPS NLB (`terraform/live/perimeter/ws-aheeva-ftps-nlb/`). TODO before apply: transfer-CMK AMI (aws/ebs source), fill ami_id + client CIDRs, and **NARROW the FTPS passive range** (source 40000-40500 = 501 ports exceeds NLB 50-listener quota → set to ~40000-40019 in both the Aheeva config and the NLB leaf).
- [ ] **FTPS passive-address (masquerade) on WS Aheeva** — because the NLB SNATs, Aheeva's FTPS PASV must advertise the NLB public IP, not its private IP (the FTPS analog of SIP externip). Confirm at cutover.
- [ ] **Separate reporting MySQL server** — scope decision for us to confirm with the client (migrate now / defer / leave in place). Not `iccmaindb`; own box, ~13 reporting consumers.
- [ ] **Durable SCP fix** (`GRNETSEC2EIPAssociate` scoped to elastic-ip ARN) — edited in `aws-accelerator-config`, rides the next LZA config zip push.

---

## Wave 2 — completion checklist (RDS + WS Aheeva + CTI v7 cutover)

Ordered runbook to take the built-but-unapplied Wave 2 leaves to a finished cutover. Leaves live at `terraform/live/production/{iccmaindb,ws-aheeva}/` and `terraform/live/perimeter/ws-aheeva-ftps-nlb/`.

### A. RDS `iccmaindb` — pre-cutover (start ~1 week ahead, replication needs lead time)

- [ ] **Source binlog prep** (source tenant): flip `binlog_format` `MIXED`→`ROW` on parameter group `enabletriggers-5-7` (dynamic, no reboot); set `binlog retention hours` ≥ 168 via `CALL mysql.rds_set_configuration(...)`.
- [ ] **Snapshot + transfer-CMK** (source): manual snapshot of `iccmaindb`; re-encrypt with a shareable customer CMK (source is on `aws/rds`, unshareable); share the CMK + snapshot to `395516496764`.
- [ ] **Copy to dest** (Production us-east-2): `copy-db-snapshot` cross-region, re-encrypt with the leaf CMK (or LZA RDS key). Record the dest snapshot id.
- [ ] **Fill tfvars**: `snapshot_identifier` = dest snapshot; `db_subnet_ids` = shared-prod data-a + data-b subnet IDs.
- [ ] **Apply the `iccmaindb` leaf** (PR → merge). Restores the DB, private, ROW binlog.
- [ ] **Start ongoing replication** (post-apply, in MySQL): create repl user on source; `CALL mysql.rds_set_external_master(...)` + `mysql.rds_start_replication` on dest; watch `Seconds_Behind_Master → 0`.

### B. WS Aheeva — pre-cutover prep

- [ ] **Narrow the FTPS passive range** on WS Aheeva's FTPS server config (source 40000-40500 = 501 ports → ~40000-40019) to fit under the NLB 50-listener quota. Match `ftps_passive_from/to` in both the `ws-aheeva` and `ws-aheeva-ftps-nlb` leaves.
- [ ] **Confirm the extra app/admin ports** actually in use (source SG had 8025/8078/8081/3389). Populate `extra_app_ports` + `extra_app_cidrs`, or leave empty to drop them.
- [ ] **FTPS client inventory**: confirm the active client source IPs (source SG 990 + passive allowlist); put in `ftps_client_cidrs` / NLB `allowed_source_cidrs`; coordinate the new endpoint with each client 7+ days ahead.

### C. Cutover window (RDS + WS Aheeva + CTI v7 together)

- [ ] Announce; tell FTPS clients to pause sends.
- [ ] Drain WS Aheeva's inbound queue on the source; confirm all files processed to RDS.
- [ ] Pause source writes; wait for replica `Seconds_Behind_Master = 0`; `mysql.rds_stop_replication`; promote dest RDS to read-write.
- [ ] **Final WS Aheeva AMI** (mutable disk): create-image at this point, transfer-CMK re-encrypt (`aws/ebs` source, reuse php73's XFER_KEY), copy+register in dest; set `ami_id` in the `ws-aheeva` leaf; apply.
- [ ] **Apply the FTPS NLB leaf**; grab `nlb_public_ips` + `nlb_dns_name`.
- [ ] **FTPS PASV masquerade**: set WS Aheeva's FTPS `pasv_address` to the NLB public IP (SNAT means it must advertise the NLB IP, not its private — FTPS analog of SIP externip).
- [ ] **Repoint DB connection strings** to the new `iccmaindb` endpoint: WS Aheeva config, webapps server (`10.12.1.65`), webapps php7.3 (`10.12.1.61`).
- [ ] **Repoint CTI v7** if needed (it reaches RDS only via WS Aheeva — likely nothing, confirm).
- [ ] Give FTPS clients the NLB endpoint; they resume sends. Verify a test file lands and processes end-to-end into the new RDS.

### D. Post-cutover

- [ ] Keep source RDS + source WS Aheeva alive (read-only / stopped) for the rollback window (default 7 days).
- [ ] Monitor: file arrival rate, WS Aheeva processing, RDS errors, replication fully stopped.
- [ ] After the window: decommission source resources; clean up migration scaffolding (dd helpers, work volumes, transfer CMKs, roles/SGs, tainted AMIs).

### Separately gating full cluster completion (not Wave 2 mechanics)

- [ ] **CTI v7 telephony vendor activation** — network path to the vendor licensing endpoint already verified from our side; waiting on Aheeva to (a) whitelist EIP `3.16.53.180` and (b) log into the server for their manufacturer-side config checks. Then `service aheevalicenseserver start` → `service aheevacti start`, verify `sip show settings`.
- [ ] **Webapps ALB** — real hostnames + DNS (+ ACM cert for HTTPS), then apply `webapps-alb`.
- [ ] **Separate reporting MySQL server** — scope decision for us to confirm with the client (own leaf if in scope).
