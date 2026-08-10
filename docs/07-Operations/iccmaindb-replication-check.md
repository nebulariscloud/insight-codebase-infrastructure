# iccmaindb — how to check replication status

Quick reference for connecting to the destination database and checking that
replication from the old tenant is healthy. Replication was started 2026-08-07.

## Facts you need

| Thing | Value |
|---|---|
| Account | Production `395516496764`, us-east-2 |
| Jump host | `i-0a1b064b3ad88f87d` (`cti-v7-ddhelper`, `10.12.1.16`, Amazon Linux 2023, SSM-managed) |
| Destination DB endpoint | `iccmaindb.cdu4e8csygjq.us-east-2.rds.amazonaws.com` |
| Destination master user | `iccawsuser` |
| Destination master password | (reset via `modify-db-instance` — stored in the password manager) |
| Source DB endpoint | `iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com` |
| Replication user | `repl_user` (lives on the **source**) |
| Started from coordinate | `mysql-bin-changelog.710575` / position `466` |

> The jump host is throwaway scaffolding left over from the CTI v7 AMI work. It is
> on the cleanup list — if it has been deleted, use any other SSM-managed instance
> in `10.12.0.0/16` (the DB security group allows that whole range on 3306).

---

## 1. Shell onto the jump host

Run in **Production `395516496764`**:

```bash
aws ssm start-session --region us-east-2 --target i-0a1b064b3ad88f87d
```

If it fails with `TargetNotConnected`, find another managed instance:
```bash
aws ssm describe-instance-information --region us-east-2 \
  --query 'InstanceInformationList[?PingStatus==`Online`].{Id:InstanceId,Name:ComputerName}' \
  --output table | cat
```

## 2. Install the MySQL client (first time on a fresh box only)

Amazon Linux 2023:
```bash
sudo dnf install -y mariadb105
mysql --version
```

Ubuntu/Debian:
```bash
sudo apt-get update -qq && sudo apt-get install -y mysql-client-core-8.0
```

## 3. Connect to the destination DB

```bash
mysql -h iccmaindb.cdu4e8csygjq.us-east-2.rds.amazonaws.com -u iccawsuser -p
```

## 4. Check replication status

```sql
SHOW SLAVE STATUS\G
```

### What healthy looks like

| Field | Want |
|---|---|
| `Slave_IO_Running` | `Yes` — connected to source, pulling binlogs |
| `Slave_SQL_Running` | `Yes` — applying them |
| `Seconds_Behind_Master` | trending **down** toward `0` |
| `Last_IO_Error` | empty |
| `Last_SQL_Error` | empty |
| `Master_SSL_Allowed` | `Yes` — channel is encrypted |
| `Master_Host` | the **source** endpoint (`...cqmvz00gvdb5.us-east-1...`) |

Progress is also visible by comparing:
- `Master_Log_File` — where the **source** currently is
- `Relay_Master_Log_File` — where we have **applied** to

The gap between those two file numbers shrinking means it is catching up.
`Slave_SQL_Running_State: System lock` during catch-up is normal — it just means
rows are actively being applied.

### Compact one-liner

From inside the jump host, without entering the MySQL prompt:

```bash
mysql -h iccmaindb.cdu4e8csygjq.us-east-2.rds.amazonaws.com -u iccawsuser -p \
  -e "SHOW SLAVE STATUS\G" \
  | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_IO_Error|Last_SQL_Error|Master_Log_File|Relay_Master_Log_File"
```

---

## 5. Watch the source's free storage

ROW-format binlogs plus 168h retention is the one thing that could cause trouble on
the source's 50 GiB volume. Run in the **source account `254422596287`, us-east-1**:

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=iccmaindb \
  --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics Minimum --output table | cat
```

Value is in **bytes** — divide by 1073741824 for GiB. Baseline when replication
started was ~24.5 GiB free of 50 GiB.

---

## Troubleshooting

| Symptom | Cause / action |
|---|---|
| `Slave_IO_Running: Connecting` | Source SG `sg-3003a540` lost the egress NAT EIPs `3.151.88.5/32` and `3.133.15.33/32` on 3306. Re-add them. |
| `Access denied for user 'repl_user'` | Wrong password, or SSL not negotiated. The last arg to `rds_set_external_master` must be `1`. |
| `Could not find first log file name` | The source binlog rotated out of retention. Replication cannot resume — take a fresh snapshot and redo Part 1. |
| `Seconds_Behind_Master` rising steadily | Source writing faster than the destination applies. Investigate before cutover. |
| Duplicate-key errors | Wrong start coordinate. Do **not** skip past them — restart from a fresh snapshot. |

## Stopping replication (cutover only)

```sql
CALL mysql.rds_stop_replication;
```
Only do this at cutover, after source writes are paused and
`Seconds_Behind_Master` is `0`.

## See also

- `iccmaindb-replication-miniguide.md` — the full 12-step Part 1 procedure
- `cti-v7-wave2-runbook.md` — all of Wave 2
- `.kiro/journal/2026-06-26-aheeva-cluster-migration-plan.md` — working history
