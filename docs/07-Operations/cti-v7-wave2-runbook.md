# CTI v7 Wave 2 — command runbook

Every command to finish Wave 2 (RDS `iccmaindb` + WS Aheeva + FTPS NLB) and the
Wave-1 webapps ALB. Copy-paste, filling the `<...>` as you go.

**Accounts / IDs (constants):**
- Source tenant: `254422596287` (us-east-1)
- Production: `395516496764` (us-east-2)
- Perimeter: `713939170920` (us-east-2)
- shared-prod VPC: `vpc-04a8720d0ddb40713`
- app-a subnet: `subnet-00d31cac6422417c4`
- Perimeter ingress VPC: `vpc-0f8cbc901a195b148`
- Perimeter public subnets: `subnet-0e4b51e5c27c3ffbf`, `subnet-079c23a68151cc828`
- Source RDS: `iccmaindb` @ `iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com`
- Source WS Aheeva: `i-025bede8c30dbcece`
- Reusable transfer CMK from php73 step: `$XFER_KEY` (source tenant) — reuse if still present, else recreate (Part 2.0)

Branch already pushed with all leaves: `wave2-leaves`.

## What must be ordered vs what runs in parallel

Not all 8 parts are sequential. The hard dependencies:

- **Part 1 (RDS) is its own track** — start it ~1 week early so replication catches up. Independent of everything else until the cutover.
- **Parts 2 → 4 → 5 are a chain**: WS Aheeva AMI (2) → deploy WS Aheeva (4) → FTPS NLB (5, needs WS Aheeva's private IP). Part 3 (narrow passive range) must be done before 5 and finalized (masquerade IP) after 5.
- **Part 6 (cutover) requires 1, 4, 5 all done** — it's the join point where RDS + WS Aheeva go live together.
- **Part 7 (webapps ALB) is fully independent** — do it anytime once you have hostnames. Not part of the cutover.
- **Part 8 (CTI v7 license) is fully independent** — do it whenever the vendor delivers the license. Nothing else waits on it.

So: Part 1 and Part 7 and Part 8 can all be in flight simultaneously; Parts 2-5 are the WS Aheeva chain; Part 6 waits for 1+4+5.

---

## PART 1 — RDS iccmaindb (start ~1 week before cutover)

### 1.PRE — Pre-flight checklist

Steps **1.0 - 1.4 are safe to run now** and are the slow part, so start them early.
Steps **1.5 - 1.7 are gated** on the three items below. Confirm each before starting 1.5.

| # | Prerequisite | How to satisfy | Status |
|---|---|---|---|
| 1 | **Data subnet IDs** for `db_subnet_ids` | the `describe-subnets` lookup in 1.5 | ☐ |
| 2 | **Source RDS SG opened to our egress NAT EIPs** on 3306 | see 1.PRE.a below | ☐ |
| 3 | **A MySQL client path to the PRIVATE destination RDS** | see 1.PRE.b below | ☐ |

Also note `terraform/live/production/iccmaindb/terraform.tfvars` still ships
placeholders (`iccmaindb-REPLACE_WITH_DEST_SNAPSHOT`,
`subnet-REPLACE_DATA_A/B`) — do **not** open the PR until 1.5 fills them, or the
plan fails.

#### 1.PRE.a Egress NAT EIPs → source RDS SG

Replication in 1.7 has the **destination** pulling from the **source's public
endpoint**. The destination lives in private `shared-prod` data subnets whose
default route is `0.0.0.0/0` → TGW → the **egress VPC NAT gateways in the
Perimeter account**. So the source sees our NAT EIPs, not the DB itself.

Get the EIPs (Perimeter account `713939170920`, us-east-2):
```bash
aws ec2 describe-nat-gateways --region us-east-2 \
  --filter "Name=tag:Name,Values=*egress-public-natgw*" \
  --query 'NatGateways[].{Name:Tags[?Key==`Name`]|[0].Value,Ip:NatGatewayAddresses[].PublicIp}' \
  --output table
```
> Note: the NAT GWs are in the **egress** VPC, *not* the ingress VPC
> `vpc-0f8cbc901a195b148` listed in the constants block above.

Then add each `/32` to source SG `sg-3003a540` on 3306 (source tenant, us-east-1).
Remove them again after cutover — they are only needed for the replication window.

Because this traffic crosses the public internet, **require SSL on the
replication user**:
```sql
ALTER USER 'repl_user'@'%' REQUIRE SSL;
```
and pass `1` (not `0`) as the last argument to `rds_set_external_master` in 1.7 so
the channel is encrypted.

#### 1.PRE.b MySQL client path to the destination

The destination RDS is **private** (`publicly_accessible = false`) — that is the
whole point of the migration. Steps 1.6/1.7 need a SQL session against it. Options:

- **SSM port-forward through a webapps box** (`10.12.1.65` or `10.12.1.61`) —
  preferred, no key distribution:
  ```bash
  aws ssm start-session --region us-east-2 \
    --target <instance-id> \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["3306"]}'
  ```
  Requires the SSM agent registered on that instance.
- CTI v7 (`10.12.0.42`) is SSH-only (CentOS, agent not installed by default) — workable but less clean.

Decide this **before** cutover, not during.

### 1.0 Source binlog prep (source tenant, us-east-1)

```bash
# binlog_format MIXED -> ROW (dynamic, no reboot)
aws rds modify-db-parameter-group --region us-east-1 \
  --db-parameter-group-name enabletriggers-5-7 \
  --parameters "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate"
```
```sql
-- In a MySQL client connected to the source (bump binlog retention):
CALL mysql.rds_show_configuration;
CALL mysql.rds_set_configuration('binlog retention hours', 168);
-- Create the replication user (used in step 1.7):
-- REQUIRE SSL because replication crosses the public internet (see 1.PRE.a).
CREATE USER 'repl_user'@'%' IDENTIFIED BY '<repl_password>' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

### 1.1 Snapshot the source (source tenant)

```bash
aws rds create-db-snapshot --region us-east-1 \
  --db-instance-identifier iccmaindb \
  --db-snapshot-identifier iccmaindb-migration
aws rds wait db-snapshot-available --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration
```

> **To be clear: yes, run the snapshot commands above.** The note below is about an
> *additional* action to skip — it does not mean skip the snapshot.
>
> **Do NOT try to capture the binlog coordinates here.** An earlier version of this
> runbook said to read them from the snapshot's create event or from
> `SHOW MASTER STATUS` on the source "around that moment". That is wrong and
> dangerous: `SHOW MASTER STATUS` returns the source's **current** position, not the
> position the snapshot was taken at. Getting it wrong means either
> **silent data loss** (position too late — the transactions in between are never
> replayed) or **broken replication** (position too early — duplicate-key errors).
>
> The coordinates are read from the **restored destination** instead — see step 1.6.

### 1.2 Re-encrypt snapshot to a shareable CMK (source is aws/rds, unshareable)

```bash
# Reuse the transfer CMK from the php73 step if it still exists; else create:
XFER_KEY=$(aws kms create-key --region us-east-1 \
  --description "cti-v7 migration transfer key" --query 'KeyMetadata.KeyId' --output text)
aws kms put-key-policy --region us-east-1 --key-id $XFER_KEY --policy-name default --policy '{"Version":"2012-10-17","Statement":[{"Sid":"EnableIAM","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::254422596287:root"},"Action":"kms:*","Resource":"*"},{"Sid":"AllowProd","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::395516496764:root"},"Action":["kms:Decrypt","kms:DescribeKey","kms:CreateGrant","kms:ReEncrypt*","kms:GenerateDataKey*"],"Resource":"*"}]}'

aws rds copy-db-snapshot --region us-east-1 \
  --source-db-snapshot-identifier iccmaindb-migration \
  --target-db-snapshot-identifier iccmaindb-migration-cmk \
  --kms-key-id $XFER_KEY
aws rds wait db-snapshot-available --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk
```

### 1.3 Share to Production (source tenant)

```bash
aws rds modify-db-snapshot-attribute --region us-east-1 \
  --db-snapshot-identifier iccmaindb-migration-cmk \
  --attribute restore --values-to-add 395516496764
```

### 1.4 Copy cross-region into Production + re-encrypt (Production, us-east-2)

> **WARNING — the key matters.** `alias/accelerator/ebs/default-encryption/key` is
> the **EBS** key (the `LZA_RDS_KEY` variable name below was misleading and is kept
> only for historical accuracy). Its key policy is scoped to EC2 via
> `kms:ViaService = ec2.<region>.amazonaws.com` and grants RDS nothing, so
> restoring from a snapshot encrypted with it fails with
> `KMSKeyNotAccessibleFault`. The snapshot must end up on a key whose policy lets
> RDS `kms:CreateGrant` — in practice the leaf's own `alias/iccmaindb-rds`. See
> `docs/07-Operations/iccmaindb-replication-miniguide.md` Step 7 for the ordering
> (the leaf's CMK does not exist until the leaf applies, so either pre-create a CMK
> or re-copy the snapshot afterwards).

```bash
LZA_RDS_KEY=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws rds copy-db-snapshot --region us-east-2 \
  --source-db-snapshot-identifier arn:aws:rds:us-east-1:254422596287:snapshot:iccmaindb-migration-cmk \
  --target-db-snapshot-identifier iccmaindb-dest \
  --kms-key-id "$LZA_RDS_KEY" --source-region us-east-1
aws rds wait db-snapshot-available --region us-east-2 \
  --db-snapshot-identifier iccmaindb-dest

# Then re-encrypt onto the leaf's CMK once it exists (see 1.5), and point
# snapshot_identifier at this copy instead:
aws rds copy-db-snapshot --region us-east-2 \
  --source-db-snapshot-identifier iccmaindb-dest \
  --target-db-snapshot-identifier iccmaindb-dest-cmk \
  --kms-key-id alias/iccmaindb-rds
aws rds wait db-snapshot-available --region us-east-2 \
  --db-snapshot-identifier iccmaindb-dest-cmk
```

### 1.5 Fill tfvars + apply the leaf

Look up the data subnets:
```bash
aws ec2 describe-subnets --region us-east-2 \
  --filters "Name=vpc-id,Values=vpc-04a8720d0ddb40713" "Name=tag:Name,Values=*shared-prod-data*" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
```
Edit `terraform/live/production/iccmaindb/terraform.tfvars`:
- `snapshot_identifier = "iccmaindb-dest"`
- `db_subnet_ids = ["<data-a>", "<data-b>"]`

PR + apply:
```bash
git fetch insight-remote
git checkout -b apply-iccmaindb insight-remote/main
git checkout wave2-leaves -- terraform/live/production/iccmaindb/
git add terraform/live/production/iccmaindb/
git commit -m "Apply iccmaindb: restore from iccmaindb-dest snapshot"
git push -u insight-remote apply-iccmaindb
gh pr create --base main --head apply-iccmaindb --title "Apply iccmaindb RDS leaf" --body "Restore-from-snapshot iccmaindb-dest into shared-prod, private, ROW binlog."
# read plan, merge -> CI applies
```

### 1.6 Read the binlog coordinates from the RESTORED destination

This is the correct source of truth for `<binlog_file>` + `<binlog_pos>`. When RDS
restores a snapshot it performs InnoDB crash recovery and writes the binlog
coordinate the snapshot corresponds to into the **destination's** MySQL error log.

Run against the newly restored instance (Production, us-east-2):
```bash
aws rds download-db-log-file-portion --region us-east-2 \
  --db-instance-identifier iccmaindb \
  --log-file-name error/mysql-error.log \
  --output text | grep -i "binlog"
```

Look for the line naming a `mysql-bin-changelog.NNNNNN` file and a position — that
pair is exactly what step 1.7 needs. If several appear, take the one written during
the restore/startup sequence (earliest after the restore), not a later rotation.

If the grep comes back empty, list the available log files and check the most recent
one rather than guessing:
```bash
aws rds describe-db-log-files --region us-east-2 \
  --db-instance-identifier iccmaindb --output table
```

**Do not proceed to 1.7 without a coordinate read from this log.** Guessing the
position is the single most likely way to silently lose or duplicate data in this
whole migration.

### 1.7 Start ongoing replication (Production, in MySQL on the new RDS)

Needs the SQL access path from **1.PRE.b** and the coordinates from **1.6**.

```sql
CALL mysql.rds_set_external_master(
  'iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com', 3306,
  'repl_user', '<repl_password>', '<binlog_file>', <binlog_pos>, 1);
CALL mysql.rds_start_replication;
SHOW SLAVE STATUS\G   -- watch Seconds_Behind_Master -> 0, IO/SQL running = Yes
```

The final argument is `1` (SSL required) rather than `0`, because this channel
crosses the public internet — see 1.PRE.a.

Verify before considering Part 1 done:
- `Slave_IO_Running: Yes` and `Slave_SQL_Running: Yes`
- `Seconds_Behind_Master` trending to `0`
- `Last_IO_Error` / `Last_SQL_Error` empty

If `Slave_IO_Running` stays `Connecting`, the source SG almost certainly doesn't have
our egress NAT EIPs yet (1.PRE.a).

---

## PART 2 — WS Aheeva AMI (transfer-CMK; final AMI at cutover)

### 2.0 Pre-flight — run this FIRST

Cheap, and it can reorder the whole plan. A marketplace product code is the one failure
no retry fixes; it killed the CTI v7 apply *after* the leaf had already merged.

```bash
aws ec2 describe-images --region us-east-1 --image-ids ami-0f38562b9d4de0dfe \
  --query 'Images[0].{Codes:ProductCodes,Platform:Platform,PlatformDetails:PlatformDetails,Root:RootDeviceName,Arch:Architecture,BDMs:BlockDeviceMappings}' \
  --output json | cat
```

How to read it:

- **`Codes` non-empty** → this is a `dd`-procedure box, not a `copy-image` box. Stop and
  reroute.
- **`Platform: windows`** → Windows box. **This is the case for WS Aheeva** — confirmed
  2026-08-07: `Codes: []`, `Platform: windows`, `PlatformDetails: Windows` (so License
  Included, not BYOL), root `/dev/sda1`, one volume. Consequences are in Part 3 and the
  leaf README: IIS FTP or FileZilla rather than vsftpd, Windows Firewall as a second
  invisible firewall, SSM port forwarding instead of SSH, and no `get-password-data`
  because the image is not Sysprepped — the existing Windows credentials come across
  and are the only way in.
- **More than one `BDMs` entry** → secondary volumes exist. `copy-image` carries them;
  the old `register-image` path would have silently dropped them.

### 2.1 Create AMI from source (source tenant, at cutover after draining queue)

> **`--no-reboot` on Windows is a rehearsal-only shortcut.** It skips filesystem
> quiescing, so the image is crash-consistent — on NTFS that can mean a `chkdsk` on
> first boot and, worse, an FTPS server caught mid-write to a file a client was
> uploading. Fine for the throwaway AMI you use to prove the chain works.
>
> For the **final cutover AMI**, after client sends are paused and the queue is drained,
> get a clean image instead: stop the FTP service so it flushes, then stop the instance,
> then `create-image` **without** `--no-reboot`. It costs a few minutes of downtime you
> have already budgeted for in the cutover window, and it removes a whole class of
> "why is this file truncated" investigation.
> ```powershell
> Stop-Service ftpsvc      # or 'FileZilla Server'
> ```
> ```bash
> aws ec2 stop-instances --region us-east-1 --instance-ids i-025bede8c30dbcece
> aws ec2 wait instance-stopped --region us-east-1 --instance-ids i-025bede8c30dbcece
> ```

```bash
WS_AMI=$(aws ec2 create-image --region us-east-1 --instance-id i-025bede8c30dbcece \
  --name "ws-aheeva-migration-$(date +%Y%m%d)" --description "WS Aheeva migration" --no-reboot \
  --query ImageId --output text)
echo "WS_AMI=$WS_AMI"
aws ec2 wait image-available --region us-east-1 --image-ids $WS_AMI
WS_SNAP=$(aws ec2 describe-images --region us-east-1 --image-ids $WS_AMI \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
echo "WS_SNAP=$WS_SNAP"
```

### 2.2 Re-encrypt the AMI onto the transfer CMK, in place (source tenant)

**Rewritten 2026-08-07.** This step used to re-encrypt the *snapshot* and then
`register-image` in the destination. Two problems with that. `register-image` makes you
hand-retype every boot attribute (`--architecture`, `--root-device-name`,
`--virtualization-type`, `--ena-support`, `--sriov-net-support`, `--boot-mode`) plus
every block device mapping, and it silently drops secondary volumes if you map only
`BlockDeviceMappings[0]`. And it was chosen in the belief that it sheds a marketplace
product code, which the 2026-07-05 CTI v7 experience disproved — the code lives on the
snapshot lineage and survives `register-image`, `copy-snapshot` and a volume
round-trip alike. Only a block-level `dd` onto a blank volume severs it.

`copy-image` re-encrypts *and* carries every boot attribute and BDM automatically. It
works same-region, which is what turns this into a two-call chain.

> **For a Windows source, `copy-image` is not merely tidier — the snapshot fallback is
> unsafe.** AWS's own guidance on creating an AMI from a snapshot says Windows, Red Hat,
> SUSE and SQL Server AMIs need correct licensing metadata, that `RegisterImage` only
> *derives* it from the snapshot's metadata when that metadata happens to be present, and
> that if the resulting AMI's `PlatformDetails` comes out empty or wrong you should
> **discard the AMI and create it from the instance instead**. Our chain re-encrypts and
> copies the snapshot twice, so that metadata is exactly what is at risk. WS Aheeva is
> Windows. Use `copy-image`.
>
> Source: [Create an AMI from a snapshot](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-an-ami-ebs.html)
> — paraphrased; content was rephrased for compliance with licensing restrictions.

> **`ec2:CopyImage` is a separate IAM action from `ec2:CopySnapshot`.** An identity that
> has been doing snapshot-based migrations may well not have it — this exact wall was hit
> on 2026-08-07 in the source tenant:
> ```
> An error occurred (UnauthorizedOperation) when calling the CopyImage operation:
> ... is not authorized to perform: ec2:CopyImage on resource: .../ami-000e85490d76316d9
> because no identity-based policy allows the ec2:CopyImage action.
> ```
> Note "no identity-based policy allows" — that is a **missing IAM grant, not an SCP
> deny** (an SCP would say "explicit deny in a service control policy"). So it is fixed
> by adding the permission, not by working around a guardrail. Minimum policy for the
> migrating identity in the **source** tenant:
> ```json
> {
>   "Version": "2012-10-17",
>   "Statement": [
>     {
>       "Sid": "MigrationCopyImage",
>       "Effect": "Allow",
>       "Action": [
>         "ec2:CopyImage",
>         "ec2:CopySnapshot",
>         "ec2:CreateTags",
>         "ec2:ModifyImageAttribute",
>         "ec2:ModifySnapshotAttribute"
>       ],
>       "Resource": "*"
>     },
>     {
>       "Sid": "MigrationKmsKeys",
>       "Effect": "Allow",
>       "Action": [
>         "kms:DescribeKey",
>         "kms:CreateGrant",
>         "kms:Decrypt",
>         "kms:ReEncryptFrom",
>         "kms:ReEncryptTo",
>         "kms:GenerateDataKeyWithoutPlaintext"
>       ],
>       "Resource": [
>         "arn:aws:kms:us-east-1:254422596287:key/e861c20e-209b-4a96-a184-10cf2e3c0c0d",
>         "arn:aws:kms:us-east-1:254422596287:key/6e7aced8-e4e6-4060-8b71-b00099d5412f"
>       ]
>     }
>   ]
> }
> ```
> The two keys are the transfer CMK and the AWS-managed `aws/ebs` key the source volumes
> sit on. `ec2:CopyImage` alone may be enough if KMS access is already inherited — if the
> retry then fails on KMS instead, the error will say so plainly.
>
> **The already-created image is reusable.** A failure at this step does not invalidate
> the `create-image` from step 2.1; re-run only the `copy-image`.

```bash
# $XFER_KEY = the transfer CMK in the SOURCE tenant. osTicket used
# e861c20e-209b-4a96-a184-10cf2e3c0c0d — reuse it rather than creating another.
# Verify it is Enabled and CUSTOMER-managed first; an aws/* key cannot be shared:
#   aws kms describe-key --region us-east-1 --key-id $XFER_KEY \
#     --query 'KeyMetadata.{State:KeyState,Mgr:KeyManager}'

WS_XFER_AMI=$(aws ec2 copy-image --region us-east-1 --source-region us-east-1 \
  --source-image-id $WS_AMI --name "ws-aheeva-xfer-$(date +%Y%m%d)" \
  --description "ws-aheeva re-encrypted onto the transfer CMK" \
  --encrypted --kms-key-id $XFER_KEY --query ImageId --output text)
echo "WS_XFER_AMI=$WS_XFER_AMI"
aws ec2 wait image-available --region us-east-1 --image-ids $WS_XFER_AMI
```

Share the AMI, its snapshots, **and** the key. All three are required — miss any one
and the destination's `copy-image` fails with a permissions error that does not tell
you which:

```bash
aws ec2 modify-image-attribute --region us-east-1 --image-id $WS_XFER_AMI \
  --launch-permission "Add=[{UserId=395516496764}]"

for S in $(aws ec2 describe-images --region us-east-1 --image-ids $WS_XFER_AMI \
    --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text); do
  aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id "$S" \
    --attribute createVolumePermission --operation-type add --user-ids 395516496764
  echo "shared $S"
done

# The transfer CMK's key policy must let Production use it: kms:DescribeKey,
# kms:Decrypt, kms:ReEncrypt*, kms:CreateGrant. Already in place if it was set up
# for the osTicket migration — confirm rather than assume.
aws kms get-key-policy --region us-east-1 --key-id $XFER_KEY \
  --policy-name default --output text | grep -A 5 395516496764
```

### 2.3 Copy cross-region into Production (Production, us-east-2)

One call. Boot attributes and every block device mapping come along, and the LZA EBS
key is applied in the same operation.

```bash
LZA_EBS_KEY=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)

WS_DEST_AMI=$(aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id $WS_XFER_AMI --name "ws-aheeva" \
  --description "WS Aheeva migrated from source tenant" \
  --encrypted --kms-key-id "$LZA_EBS_KEY" --query ImageId --output text)
echo "WS_DEST_AMI=$WS_DEST_AMI"
aws ec2 wait image-available --region us-east-2 --image-ids $WS_DEST_AMI

# Verify before putting it in tfvars. ProductCodes MUST be empty.
aws ec2 describe-images --region us-east-2 --image-ids $WS_DEST_AMI \
  --query 'Images[0].{State:State,Codes:ProductCodes,Root:RootDeviceName,Arch:Architecture,Platform:PlatformDetails,BDMs:BlockDeviceMappings[].DeviceName}' \
  --output json | cat
```

> **If `copy-image` fails with `OptInRequired`**, the source AMI carries a marketplace
> product code and no amount of copying strips it. Route to the block-level `dd`
> procedure in the CTI v7 journal instead. Run 2.0 and you will know this before
> spending an hour on copies.

---

## PART 3 — narrow the FTPS passive range (on WS Aheeva, before NLB apply)

**WS Aheeva is a Windows box** (confirmed 2026-08-07: `Platform: windows`). So the FTPS
server is IIS FTP or FileZilla Server, not vsftpd. Get in over SSM — no need to open
3389:

```bash
aws ssm start-session --region us-east-2 --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
# then RDP to localhost:13389
```

Identify which server it is first:

```powershell
Get-Service ftpsvc, 'FileZilla Server' -ErrorAction SilentlyContinue |
  Select-Object Name, Status
Get-NetTCPConnection -LocalPort 990 -State Listen |
  Select-Object OwningProcess |
  ForEach-Object { Get-Process -Id $_.OwningProcess | Select-Object Name, Path }
```

### If IIS FTP (`ftpsvc`)

The data channel port range is a **server-wide** setting, not per-site, and it lives in
`applicationHost.config` under `<system.ftpServer><firewallSupport>`:

```powershell
Import-Module WebAdministration

# Passive range - must match both Terraform leaves (40000-40019)
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter 'system.ftpServer/firewallSupport' -Name 'lowDataChannelPort'  -Value 40000
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter 'system.ftpServer/firewallSupport' -Name 'highDataChannelPort' -Value 40019

# External IP the server advertises in PASV replies = the NLB public IP (Part 5).
# Without this the server hands out its own private 10.12.1.66 and every client's
# data connection fails.
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter 'system.ftpServer/firewallSupport' -Name 'externalIp4Address' -Value '<NLB public IP>'

# The range change requires a service restart, not just an IIS reset
Restart-Service ftpsvc
```

> Two IIS-specific traps. **(1)** A per-site `ftpServer/firewallSupport` override can
> shadow the server-level value — check the site as well as the machine level. **(2)**
> IIS FTP has its own **IPv4 Address and Domain Restrictions** feature. If the site uses
> it to allowlist client IPs, those rules stop matching after migration because the NLB
> SNATs and traffic arrives from `10.0.0.0/20`. Same for `userIsolation` paths that
> reference the old hostname.

### If FileZilla Server

GUI: Settings → Passive mode settings → *Use custom port range* `40000`-`40019`, and
*Use the following IP* = the NLB public IP. Then restart the service. The equivalent
lives in `FileZilla Server.xml` if you prefer editing the file, but restart the service
either way.

### Then, whichever it is — Windows Firewall

The security group is not the only firewall. Check that 990 and `40000-40019` are open
inbound in Windows Firewall **and** that no rule is scoped to the clients' public IPs,
because after migration traffic arrives from NLB private addresses:

```powershell
New-NetFirewallRule -DisplayName 'FTPS control 990' -Direction Inbound `
  -Protocol TCP -LocalPort 990 -RemoteAddress 10.0.0.0/20 -Action Allow
New-NetFirewallRule -DisplayName 'FTPS passive 40000-40019' -Direction Inbound `
  -Protocol TCP -LocalPort 40000-40019 -RemoteAddress 10.0.0.0/20 -Action Allow

# Find pre-existing rules still scoped to client public IPs - these will not match
Get-NetFirewallRule -DisplayName '*FTP*' | ForEach-Object {
  [pscustomobject]@{
    Rule   = $_.DisplayName
    Remote = ($_ | Get-NetFirewallAddressFilter).RemoteAddress -join ','
    Ports  = ($_ | Get-NetFirewallPortFilter).LocalPort -join ','
  }
}
```

**Also update anything inside the box that references the old address.** The source
private IP was `172.30.2.200`; the new one is `10.12.1.66`. Same class of problem as
CTI v7's `externip`, and just as easy to miss.

---

## PART 4 — deploy WS Aheeva (Production)

Edit `terraform/live/production/ws-aheeva/terraform.tfvars`:
- `ami_id = "<WS_DEST_AMI>"`
- confirm `private_ip = "10.12.1.66"` free (see below), `ftps_passive_to = 40019`

```bash
# confirm .66 free in app-a
aws ec2 describe-network-interfaces --region us-east-2 \
  --filters "Name=subnet-id,Values=subnet-00d31cac6422417c4" \
  --query 'NetworkInterfaces[].PrivateIpAddress' --output text | tr '\t' '\n' | sort -t. -k4 -n
```
```bash
git checkout -b apply-ws-aheeva insight-remote/main
git checkout wave2-leaves -- terraform/live/production/ws-aheeva/
# edit tfvars (ami_id), then:
git add terraform/live/production/ws-aheeva/
git commit -m "Apply ws-aheeva leaf"
git push -u insight-remote apply-ws-aheeva
gh pr create --base main --head apply-ws-aheeva --title "Apply ws-aheeva leaf" --body "WS Aheeva FTPS file-loader into shared-prod, private, .66."
# merge -> apply. Then get its private IP:
#   terraform output -raw private_ip   (or from CI)
```

---

## PART 5 — deploy the FTPS NLB (Perimeter)

Edit `terraform/live/perimeter/ws-aheeva-ftps-nlb/terraform.tfvars`:
- `ws_aheeva_private_ip = "10.12.1.66"` (match Part 4)
- `ftps_passive_to = 40019` (match Parts 3 & 4)
- `allowed_source_cidrs = [<confirmed FTPS client /32s>]`

```bash
git checkout -b apply-ftps-nlb insight-remote/main
git checkout wave2-leaves -- terraform/live/perimeter/ws-aheeva-ftps-nlb/
git add terraform/live/perimeter/ws-aheeva-ftps-nlb/
git commit -m "Apply ws-aheeva FTPS NLB"
git push -u insight-remote apply-ftps-nlb
gh pr create --base main --head apply-ftps-nlb --title "Apply WS Aheeva FTPS NLB" --body "FTPS ingress NLB (990 + passive 40000-40019) fronting WS Aheeva."
# merge -> apply. Then read the public IPs to give clients:
#   terraform output nlb_public_ips ; terraform output -raw nlb_dns_name
```

Go back to Part 3 and set the FTPS `pasv_address`/masquerade to an NLB public IP.

---

## PART 6 — cutover (RDS + WS Aheeva together)

1. Announce; FTPS clients pause sends.
2. Drain WS Aheeva inbound queue on source; confirm all files processed.
3. Pause source writes; on new RDS wait `Seconds_Behind_Master=0`; `CALL mysql.rds_stop_replication;`.
4. Repoint DB connection strings to the new RDS endpoint (`terraform output -raw endpoint` from iccmaindb leaf):
   - WS Aheeva config (in the box, SSH/SSM)
   - webapps server `10.12.1.65`
   - webapps php7.3 `10.12.1.61`
5. Give clients the NLB endpoint/IPs; resume sends; verify a test file lands + processes into the new RDS.
6. Keep source RDS + WS Aheeva alive read-only/stopped for rollback (7 days default).

---

## PART 7 — Wave 1 finisher: webapps ALB (independent of Wave 2)

Needs real hostnames (+ later ACM cert). Edit
`terraform/live/perimeter/webapps-alb/terraform.tfvars`:
- `webapps_server_host` / `webapps_php73_host` = real DNS names
- `certificate_arn` = "" (HTTP-only) until a cert exists

```bash
git checkout -b apply-webapps-alb insight-remote/main
git checkout wave2-leaves -- terraform/live/perimeter/webapps-alb/
git add terraform/live/perimeter/webapps-alb/
git commit -m "Apply webapps ALB (HTTP-only)"
git push -u insight-remote apply-webapps-alb
gh pr create --base main --head apply-webapps-alb --title "Apply webapps ALB" --body "Dedicated HTTP-only ALB fronting the 2 webapps."
# merge -> apply. Then DNS A-alias both hostnames -> terraform output -raw alb_dns_name
```

Later, when a cert exists: request/import ACM cert in us-east-2 (Perimeter),
set `certificate_arn`, re-apply → HTTP auto-redirects to HTTPS.

---

## PART 8 — CTI v7 license (independent, vendor-gated)

When Aheeva returns the license file (issued for RLM hostid `02417393bdd5`,
IP `3.16.53.180` allowlisted on 5053/50555):
```bash
# SSH into CTI v7 (temp SG rule + cti-v7-admin key), drop the .lic into
# /usr/local/AheevaLicenses/licenses/, then:
sudo service aheevalicenseserver start
sudo service aheevacti start
sudo asterisk -rx "sip show settings" | grep -iA1 extern   # expect 3.16.53.180
```

---

## Cleanup (after cutover + rollback window)

- Source dd helper `i-07b9f51d2f3be9f54`, role/profile `cti-v7-dd-ssm-role`/`-profile`, its SG, work volumes.
- Prod dead helper `i-0a1b064b3ad88f87d`, vols `vol-02b91a4975cbd3097`, `vol-093f3896e7b2781d9`.
- Tainted CTI v7 AMI `ami-07b69272c5caf9d33` (deregister).
- Transfer CMKs (`$XFER_KEY` etc.) once no longer needed.
- Temp SSH SG rules opened for admin access.
