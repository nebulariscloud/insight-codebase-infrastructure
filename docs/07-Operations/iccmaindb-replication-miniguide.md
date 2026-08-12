# iccmaindb replication — mini guide (Wave 2, Part 1)

Start-to-finish commands for replicating the CTI v7 main database from the old
tenant into the new one. Companion to `cti-v7-wave2-runbook.md` Part 1 — this is the
condensed, in-order version with the checks inline.

**Nothing here is destructive to the source database.** The only changes to the
source are: a dynamic parameter flip, a binlog retention setting, and one new
read-only replication user. No restart, no failover, no downtime.

---

## Direction of travel (so the user question doesn't come up again)

```
NEW DB (destination, us-east-2)  ──connects out──>  OLD DB (source, us-east-1)
        pulls the changes                            holds repl_user
```

- `repl_user` is created on the **SOURCE only**. Nothing to create on the destination.
- The destination is a **snapshot restore**, so it inherits every MySQL account from
  the source, including the app users and the **master user password**. At cutover the
  apps change only the *hostname*, not the credentials.

---

## Constants

| Thing | Value |
|---|---|
| Source account | `254422596287` (us-east-1) |
| Source DB | `iccmaindb` |
| Source endpoint | `iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com:3306` |
| Source param group | `enabletriggers-5-7` |
| Source SG | `sg-3003a540` |
| Destination account | Production `395516496764` (us-east-2) |
| shared-prod VPC | `vpc-04a8720d0ddb40713` |
| Perimeter account | `713939170920` |

Decide now and keep somewhere safe: **`<repl_password>`**. Needed twice (step 1 and step 8).

> Tip: append `| cat` to any `--output table` command — CloudShell's pager truncates.

---

## Step 0 — Access prerequisites (do this first)

You need a **MySQL client session against the source**. The source is
`PubliclyAccessible=true` but only ~18 specific IPs are allowed on 3306, and your
workstation is probably not one of them.

Check your public IP:
```bash
curl -s https://checkip.amazonaws.com
```

Then temporarily allow it on the source SG (source account):
```bash
aws ec2 authorize-security-group-ingress --region us-east-1 \
  --group-id sg-3003a540 \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=<your-ip>/32,Description=temp-migration-admin}]"
```
**Remove it when you're done with Part 1:**
```bash
aws ec2 revoke-security-group-ingress --region us-east-1 \
  --group-id sg-3003a540 \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=<your-ip>/32}]"
```

Connect (you'll need the source master credentials):
```bash
mysql -h iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com -P 3306 -u <master_user> -p
```

---

## Step 1 — Baseline checks on the source

Storage headroom (should be comfortable — was ~24.5 GiB free of 50 GiB):
```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=iccmaindb \
  --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics Minimum --output table | cat
```
Value is in **bytes** — divide by 1073741824 for GiB.

Current binlog footprint (in MySQL):
```sql
SHOW BINARY LOGS;
```

Optional safety net — storage autoscaling (no downtime, only costs if it triggers):
```bash
aws rds describe-db-instances --region us-east-1 \
  --db-instance-identifier iccmaindb \
  --query 'DBInstances[].{Allocated:AllocatedStorage,MaxAutoscale:MaxAllocatedStorage}' \
  --output table | cat

aws rds modify-db-instance --region us-east-1 \
  --db-instance-identifier iccmaindb \
  --max-allocated-storage 150 --apply-immediately
```
Only scales up, never down. Give the client a heads-up first — it's their prod DB.

---

## Step 2 — Flip binlog_format to ROW (source)

Confirmed **dynamic** + modifiable, so no reboot and no downtime.

```bash
aws rds modify-db-parameter-group --region us-east-1 \
  --db-parameter-group-name enabletriggers-5-7 \
  --parameters "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate"
```

**Check the group took it:**
```bash
aws rds describe-db-parameters --region us-east-1 \
  --db-parameter-group-name enabletriggers-5-7 \
  --query "Parameters[?ParameterName=='binlog_format'].{Value:ParameterValue,ApplyMethod:ApplyMethod}" \
  --output table | cat
```
Expect `ROW` / `immediate`.

**Check what MySQL actually sees** — this is the authoritative one:
```sql
SHOW VARIABLES LIKE 'binlog_format';
```
Must read `ROW` before you snapshot. If it still says `MIXED`, stop and diagnose.

---

## Step 3 — Retention + replication user (source, in MySQL)

```sql
-- See current retention
CALL mysql.rds_show_configuration;

-- 168 hours = 7 days. Drop to 48-72 if storage is tight.
CALL mysql.rds_set_configuration('binlog retention hours', 168);

-- REQUIRE SSL: this channel crosses the public internet.
CREATE USER 'repl_user'@'%' IDENTIFIED BY '<repl_password>' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

**Checks:**
```sql
CALL mysql.rds_show_configuration;            -- retention now 168
SELECT user, host, ssl_type FROM mysql.user WHERE user='repl_user';  -- ssl_type = ANY
SHOW GRANTS FOR 'repl_user'@'%';              -- REPLICATION SLAVE present
```

---

## Step 4 — Snapshot the source

```bash
aws rds create-db-snapshot --region us-east-1 \
  --db-instance-identifier iccmaindb \
  --db-snapshot-identifier iccmaindb-migration

aws rds wait db-snapshot-available --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration
```

MultiAZ, so the snapshot is taken from the standby — no I/O impact on the primary.

> **To be clear: yes, run the two commands above.** The note below is about an
> *additional* action to skip — it does not mean skip the snapshot.
>
> **Do NOT try to record binlog coordinates at this point.** Older versions of this
> procedure said to run `SHOW MASTER STATUS` on the source here and write down the
> file/position. Don't. That returns the source's *current* position, which does not
> correspond to the snapshot — using it silently loses data (position too late) or
> breaks replication with duplicate keys (too early). The correct coordinates are
> read from the restored destination in **Step 9**.

**Check:**
```bash
aws rds describe-db-snapshots --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration \
  --query 'DBSnapshots[].{Status:Status,Created:SnapshotCreateTime,Encrypted:Encrypted,KMS:KmsKeyId}' \
  --output table | cat
```

---

## Step 5 — Re-encrypt the snapshot to a shareable CMK (source)

The source snapshot is encrypted with `aws/rds` (an AWS-managed key), which
**cannot be shared cross-account**. So re-encrypt with a customer-managed key.

First check whether the transfer CMK from the earlier php73 work still exists:
```bash
aws kms list-aliases --region us-east-1 \
  --query "Aliases[?contains(AliasName,'xfer') || contains(AliasName,'transfer')]" \
  --output table | cat
```

If yes, set `XFER_KEY` to it. Otherwise create one:
```bash
XFER_KEY=$(aws kms create-key --region us-east-1 \
  --description "cti-v7 migration transfer key" \
  --query 'KeyMetadata.KeyId' --output text)
echo "XFER_KEY=$XFER_KEY"

aws kms put-key-policy --region us-east-1 --key-id $XFER_KEY --policy-name default --policy '{"Version":"2012-10-17","Statement":[{"Sid":"EnableIAM","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::254422596287:root"},"Action":"kms:*","Resource":"*"},{"Sid":"AllowProd","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::395516496764:root"},"Action":["kms:Decrypt","kms:DescribeKey","kms:CreateGrant","kms:ReEncrypt*","kms:GenerateDataKey*"],"Resource":"*"}]}'
```

Copy the snapshot onto that key:
```bash
aws rds copy-db-snapshot --region us-east-1 \
  --source-db-snapshot-identifier iccmaindb-migration \
  --target-db-snapshot-identifier iccmaindb-migration-cmk \
  --kms-key-id $XFER_KEY

aws rds wait db-snapshot-available --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk
```

---

## Step 6 — Share to Production (source)

```bash
aws rds modify-db-snapshot-attribute --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk \
  --attribute restore --values-to-add 395516496764
```

**Check the share landed:**
```bash
aws rds describe-db-snapshot-attributes --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk --output table | cat
```

---

## Step 7 — Copy cross-region into Production (destination account)

Switch to Production `395516496764`. This is the slow step.

> **Do NOT use `alias/accelerator/ebs/default-encryption/key` here.** Despite what
> an earlier version of this guide called it (`LZA_RDS_KEY`), that is the **EBS**
> key, and its key policy is scoped to EC2:
> `{"Sid":"ec2", "Condition":{"kms:ViaService":"ec2.<region>.amazonaws.com"}}`.
> It grants RDS nothing, so a restore from a snapshot encrypted with it fails:
>
> ```
> KMSKeyNotAccessibleFault: The specified KMS key [...] does not exist, is not
> enabled or you do not have permissions to access it
> ```
>
> The snapshot must end up on a key **RDS can use** — i.e. one whose policy allows
> `rds.amazonaws.com` (or the calling role) to `kms:CreateGrant`.

The destination key we want is the leaf's own CMK, `alias/iccmaindb-rds` — but that
key does not exist until the leaf applies (Step 8). Two ways to handle the ordering:

**Option A (fewer steps):** create the destination CMK out-of-band first, with an
RDS-capable policy, and have the leaf adopt it rather than create its own.

**Option B (what we actually did):** copy with any available key now, apply the leaf
(which creates `alias/iccmaindb-rds` with the right policy), then re-copy the
snapshot onto that CMK and point `snapshot_identifier` at the new copy:

```bash
# first copy (cross-region, any key)
aws rds copy-db-snapshot --region us-east-2 \
  --source-db-snapshot-identifier arn:aws:rds:us-east-1:254422596287:snapshot:iccmaindb-migration-cmk \
  --target-db-snapshot-identifier iccmaindb-dest \
  --kms-key-id alias/accelerator/ebs/default-encryption/key --source-region us-east-1
aws rds wait db-snapshot-available --region us-east-2 \
  --db-snapshot-identifier iccmaindb-dest

# after Step 8 has created alias/iccmaindb-rds: re-encrypt onto it
aws rds copy-db-snapshot --region us-east-2 \
  --source-db-snapshot-identifier iccmaindb-dest \
  --target-db-snapshot-identifier iccmaindb-dest-cmk \
  --kms-key-id alias/iccmaindb-rds
aws rds wait db-snapshot-available --region us-east-2 \
  --db-snapshot-identifier iccmaindb-dest-cmk
```

Then set `snapshot_identifier = "iccmaindb-dest-cmk"`.

**Related:** `kms:CreateGrant` is **absent** from
`aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json`, which
is an explicit allow-list. The leaf works around this with an explicit key policy on
its own CMK. Adding `kms:CreateGrant` to that allow-policy (an LZA pipeline change)
would be the systemic fix — worth batching with other allow-policy gaps.

**Check:**
```bash
aws rds describe-db-snapshots --region us-east-2 \
  --db-snapshot-identifier iccmaindb-dest \
  --query 'DBSnapshots[].{Status:Status,Pct:PercentProgress,Encrypted:Encrypted}' \
  --output table | cat
```
Wait for `available` / `100`.

---

## Step 8 — Deploy the destination DB (Terraform PR)

Get the data subnet IDs:
```bash
aws ec2 describe-subnets --region us-east-2 \
  --filters "Name=vpc-id,Values=vpc-04a8720d0ddb40713" "Name=tag:Name,Values=*shared-prod-data*" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table | cat
```

Edit `terraform/live/production/iccmaindb/terraform.tfvars`:
- `snapshot_identifier = "iccmaindb-dest"`
- `db_subnet_ids = ["<data-a>", "<data-b>"]`

Then PR (never a local apply — CI applies on merge):
```bash
git fetch insight-remote
git checkout -b apply-iccmaindb insight-remote/main
git checkout wave2-leaves -- terraform/live/production/iccmaindb/
# edit tfvars now if not already done
terraform fmt -check -recursive -diff terraform/live/production/iccmaindb
git add terraform/live/production/iccmaindb/
git commit -m "Apply iccmaindb: restore from iccmaindb-dest snapshot"
git push -u insight-remote apply-iccmaindb
gh pr create --base main --head apply-iccmaindb \
  --title "Apply iccmaindb RDS leaf" \
  --body "Restore-from-snapshot iccmaindb-dest into shared-prod. Private, ROW binlog."
```

**Read the plan before merging.** Expect a clean create (DB instance + subnet group +
parameter group + SG + CMK). Nothing should be destroyed.

---

## Step 9 — Read the binlog coordinates from the RESTORED destination

This is the critical step. During the restore, RDS performs InnoDB crash recovery and
reports the binlog coordinate the snapshot corresponds to.

**Easiest source — the RDS event log** (this is where it reliably shows up):

```bash
aws rds describe-events --region us-east-2 \
  --source-identifier iccmaindb --source-type db-instance \
  --duration 1440 \
  --query 'Events[?contains(Message,`Binlog position`)].[Date,Message]' \
  --output table | cat
```

You are looking for an event like:

```
Binlog position from crash recovery is mysql-bin-changelog.710575 466
```

which gives `binlog_file = mysql-bin-changelog.710575` and `binlog_pos = 466`.
It is emitted during the restore's startup — before the "Restored from snapshot"
event — so it corresponds to the snapshot point, which is exactly what Step 11 needs.

**Fallback — the error log.** Note `error/mysql-error.log` is often **0 bytes**; the
content lives in the rotated `error/mysql-error-running.log`:

```bash
aws rds describe-db-log-files --region us-east-2 \
  --db-instance-identifier iccmaindb --output table | cat

aws rds download-db-log-file-portion --region us-east-2 \
  --db-instance-identifier iccmaindb \
  --log-file-name error/mysql-error-running.log \
  --output text | grep -i "binlog"
```

**Do not proceed without a coordinate from one of these sources. Never guess it.**

---

## Step 10 — Open the source SG to your egress NAT EIPs

The destination reaches the source's public endpoint via the **egress VPC NAT
gateways in the Perimeter account** (not the ingress VPC).

```bash
# Perimeter account 713939170920
aws ec2 describe-nat-gateways --region us-east-2 \
  --filter "Name=tag:Name,Values=*egress-public-natgw*" \
  --query 'NatGateways[].{Name:Tags[?Key==`Name`]|[0].Value,Ip:NatGatewayAddresses[].PublicIp}' \
  --output table | cat
```

Add each as a `/32` on 3306 to `sg-3003a540` (source account):
```bash
aws ec2 authorize-security-group-ingress --region us-east-1 \
  --group-id sg-3003a540 \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=<nat-eip>/32,Description=temp-replication}]"
```
Remove after cutover.

---

## Step 11 — Start replication (on the destination, in MySQL)

You need a SQL session against the **private** destination. Use SSM port-forward
through a webapps box (`10.12.1.65` or `10.12.1.61`):
```bash
aws ssm start-session --region us-east-2 \
  --target <webapps-instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<new-rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["3306"]}'
```
Then connect to `127.0.0.1:3306` with the **source's master credentials** (inherited
via the restore).

```sql
CALL mysql.rds_set_external_master(
  'iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com', 3306,
  'repl_user', '<repl_password>', '<binlog_file>', <binlog_pos>, 1);
CALL mysql.rds_start_replication;
```
Last argument `1` = SSL required.

**Checks:**
```sql
SHOW SLAVE STATUS\G
```
Want to see:
- `Slave_IO_Running: Yes`
- `Slave_SQL_Running: Yes`
- `Seconds_Behind_Master` trending toward `0`
- `Last_IO_Error` / `Last_SQL_Error` empty

Troubleshooting:
| Symptom | Cause |
|---|---|
| `Slave_IO_Running: Connecting` | source SG missing your egress NAT EIPs (Step 10) |
| Access denied for `repl_user` | wrong password, or SSL not negotiated (last arg must be `1`) |
| Duplicate key errors | binlog position too early — wrong coordinate |
| Replication lags forever / gaps | position too late — data missed; restart from a fresh snapshot |

---

## Step 12 — Monitor during the catch-up window

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=iccmaindb \
  --start-time "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics Minimum --output table | cat
```
Watch the source's free storage for the first day or two — ROW binlogs plus 7-day
retention is the one thing that could bite. `SHOW SLAVE STATUS` on the destination
should stay healthy with `Seconds_Behind_Master` near zero.

---

## Cleanup checklist (after cutover, not before)

- [ ] Remove your admin `/32` from source SG `sg-3003a540`
- [ ] Remove the egress NAT EIP `/32`s from `sg-3003a540`
- [ ] `CALL mysql.rds_stop_replication;` on the destination at cutover
- [ ] Drop the unused `repl_user` copy on the destination (harmless if left)
- [ ] Drop `repl_user` on the source once replication is finished with
- [ ] Delete the intermediate snapshots (`iccmaindb-migration`, `iccmaindb-migration-cmk`)
- [ ] Reconsider binlog retention on the source (or decommission it entirely)
- [ ] Remove `--max-allocated-storage` if it was only for the migration window

---

## Stop points

Two places to pause rather than push through:

1. **After Step 2** — if `SHOW VARIABLES` doesn't say `ROW`, don't snapshot.
2. **After Step 9** — if the error log yields no binlog coordinate, don't start
   replication. Guessing the position is the single most likely way to silently
   lose data in this migration.

## See also

- `cti-v7-wave2-runbook.md` — full Wave 2 (all 8 parts), Part 1 is the long form of this
- `terraform/live/production/iccmaindb/README.md` — the leaf's own notes
- `cti-v7-cluster-migration-plan.md` — the overall migration plan
