# RDS iccmaindb (Production / shared-prod) — Wave 2

Destination MySQL 5.7 database for the CTI v7 cluster, migrated from the source
tenant (`254422596287` / `us-east-1`) RDS `iccmaindb`.

> **CI note — if a merge does not create anything.** This leaf merged twice
> (PRs #50, #51) during a GitHub Actions incident in which `push` and
> `pull_request` events were not delivered at all, so no plan or apply ever ran
> and nothing was provisioned. GitHub does not replay missed events, so a merge
> that silently produced no workflow run needs a **fresh commit touching any file
> in this leaf** to make `detect` surface it again. Verify with
> `gh run list --workflow terraform`; if the run is absent (rather than skipped),
> suspect event delivery, not the config. A `workflow_dispatch` run is a useful
> probe — it plans but deliberately cannot apply, since the apply job is gated on
> `github.event_name == 'push'`.

## Source facts (confirmed)

| Fact | Value |
|---|---|
| Engine | MySQL `5.7.44` |
| Class / storage | `db.t3.small`, 50 GiB gp2, MultiAZ |
| Encryption | `aws/rds` (AWS-managed — **not shareable**) |
| Endpoint | `iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com:3306` |
| Parameter group | `enabletriggers-5-7` (`binlog_format=MIXED`, `log_bin_trust_function_creators=1`) |
| Public | `PubliclyAccessible=true`, 18 public IPs on 3306 (posture we are NOT reproducing) |
| Backups | 7-day retention, 07:00-09:00 UTC |

## What this leaf owns

- A customer CMK (`alias/iccmaindb-rds`) for encryption at rest.
- DB subnet group across shared-prod data subnets.
- Parameter group `iccmaindb-mysql57` with `binlog_format=ROW` +
  `log_bin_trust_function_creators=1`.
- Security group: MySQL 3306 from app-tier CIDRs only. **Private** (no public IP).
- The RDS instance, **restored from a snapshot** of the source.

## Why restore-from-snapshot + binlog replication (not a native replica)

RDS-native cross-account read replicas are **not supported for non-Aurora
MySQL**. So the mechanic is snapshot-restore to seed the data, then ongoing
binlog replication to stay in sync until cutover.

## Pre-cutover runbook

### 0. Source prep (source tenant, AWS CLI — do a week ahead)

```bash
# binlog_format MIXED -> ROW (dynamic, no reboot). Required for replication.
aws rds modify-db-parameter-group --region us-east-1 \
  --db-parameter-group-name enabletriggers-5-7 \
  --parameters "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate"

# binlog retention >= 168h so binlogs survive the catch-up window (run in MySQL):
#   CALL mysql.rds_show_configuration;
#   CALL mysql.rds_set_configuration('binlog retention hours', 168);
```

### 1. Snapshot -> shareable CMK -> share -> copy -> re-encrypt

The source is on `aws/rds` (unshareable), so re-encrypt with a customer CMK
first (same pattern the EC2 boxes used):

```bash
# Source tenant:
aws rds create-db-snapshot --region us-east-1 \
  --db-instance-identifier iccmaindb --db-snapshot-identifier iccmaindb-migration

# Re-encrypt to a shareable CMK (create one; grant Production use), then:
aws rds copy-db-snapshot --region us-east-1 \
  --source-db-snapshot-identifier iccmaindb-migration \
  --target-db-snapshot-identifier iccmaindb-migration-cmk \
  --kms-key-id <source-transfer-CMK>

aws rds modify-db-snapshot-attribute --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk \
  --attribute restore --values-to-add 395516496764
```

```bash
# Production / us-east-2: copy cross-region + re-encrypt with THIS leaf's CMK.
# (Apply the leaf once with a placeholder to create the CMK, or create the CMK
#  first, or use the LZA RDS key — then copy into it.)
aws rds copy-db-snapshot --region us-east-2 \
  --source-db-snapshot-identifier arn:aws:rds:us-east-1:254422596287:snapshot:iccmaindb-migration-cmk \
  --target-db-snapshot-identifier iccmaindb-dest \
  --kms-key-id <this-leaf's CMK ARN or the LZA RDS key> \
  --source-region us-east-1
```

Put `iccmaindb-dest` in `terraform.tfvars` as `snapshot_identifier`.

> Chicken-and-egg note: the leaf creates its own CMK, but the cross-region
> copy needs a key to exist first. Options: (a) copy into the LZA-managed RDS
> key and let the restore re-key to this leaf's CMK, or (b) create the CMK
> out-of-band first and reference it. Simplest is (a).

### 2. Apply this leaf

Restores the instance from `iccmaindb-dest`. Comes up private, `ROW` binlog,
triggers-trusted.

### 3. Start ongoing binlog replication (after apply, in MySQL)

```sql
-- On the source: create a replication user (once). REQUIRE SSL — this channel
-- crosses the public internet.
CALL mysql.rds_set_configuration('binlog retention hours', 168);
-- On the destination: point at the source and start. Last arg 1 = SSL required.
CALL mysql.rds_set_external_master(
  'iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com', 3306,
  'repl_user', 'repl_password', '<binlog_file>', <binlog_pos>, 1);
CALL mysql.rds_start_replication;
SHOW SLAVE STATUS\G   -- watch Seconds_Behind_Master -> 0
```

**Where `<binlog_file>` / `<binlog_pos>` come from:** read them from **this
restored instance's** MySQL error log, *not* from `SHOW MASTER STATUS` on the
source. `SHOW MASTER STATUS` returns the source's current position, which does not
correspond to the snapshot — using it silently loses data (position too late) or
breaks replication with duplicate keys (too early). RDS writes the correct
coordinate during the restore's InnoDB crash recovery:

```bash
aws rds download-db-log-file-portion --region us-east-2 \
  --db-instance-identifier iccmaindb \
  --log-file-name error/mysql-error.log \
  --output text | grep -i "binlog"
```

Also required before replication will connect: the source SG `sg-3003a540` must
allow 3306 from our **egress VPC NAT gateway EIPs** (Perimeter account), since the
destination reaches the source's public endpoint via those. See
`docs/07-Operations/iccmaindb-replication-miniguide.md` Step 10.

### 4. Cutover

1. Pause writes on the source (stop WS Aheeva ingest).
2. Wait for `Seconds_Behind_Master = 0`.
3. `CALL mysql.rds_stop_replication;` on the destination.
4. Repoint WS Aheeva + the two webapps at this leaf's `endpoint` output.
5. Keep the source RDS read-only for the rollback window (default 7 days).

## Notes

- `snapshot_identifier` and `engine_version` are in `lifecycle.ignore_changes`
  so post-restore drift doesn't try to replace the live DB.
- App clients that need 3306: WS Aheeva + the two webapps (Wave 1 boxes flip
  their connection strings from the source endpoint to this one at cutover).
- The separate MySQL server (the reporting DB on its own box, 13 clients) is a
  DIFFERENT database — not this instance, not part of this leaf.

## See also

- `cti-v7-cluster-migration-plan.md` — overall plan
- `snapshot-ami-migration-guide.md` — the CMK re-encrypt/share pattern
