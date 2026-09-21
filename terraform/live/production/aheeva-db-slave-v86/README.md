# Aheeva DB Slave v8.6 — Production / shared-prod

MariaDB replica of the Aheeva CTI v8.6 box, migrated out of the source tenant.
Private instance, no public exposure, no load balancer.

| | |
|---|---|
| **Source** | `i-05b16ebe4f90c2c03` — 254422596287 / us-east-1, private `10.0.1.172`, EIP `3.228.31.130` |
| **Destination** | Production `395516496764` / us-east-2, `shared-prod-app-a`, private `10.12.1.54` |
| **AMI** | `ami-07c696aab9f4b6c43` — `ProductCodes: null` (verified) |
| **OS / DB** | CentOS 7.9.2009 / **MariaDB** (not MySQL) |
| **Size** | `m5.2xlarge`, matching source |
| **Disks** | `/dev/sda1` 200 GiB root + `/dev/sdf` 16 GiB data, both from the AMI |
| **Full procedure** | `docs/07-Operations/aheeva-v86-dd-migration-runbook.md` |

## Why the AMI provenance is unusual

The source instance carried the AWS Marketplace product code
`cvugziknvmxgqna9noibqnnsy` — the **delisted** CentOS 7 listing. A product code
cannot be stripped by any API path: `copy-image`, `copy-snapshot` and a volume
round-trip all re-inherit it, and Production cannot even `AttachVolume` a
tainted-lineage volume. The only operation that severs it is writing the bytes
into a volume AWS created **blank**, because a blank volume has no lineage.

```
i-05b16ebe4f90c2c03
  └─ create-image (read lock held)      ami-0710301c8fde3db8a   [product-coded]
       ├─ snap-0dc9232b680733b3b  200 GiB
       └─ snap-0d623a456d3b6b01b   16 GiB
            │  FSR-hydrated volumes, then block-level dd onto blank volumes
            │  IN THE SOURCE TENANT (the only account subscribed to the listing)
            ▼
       snapshot the blanks  →  clean, no lineage  →  shared to Production
            ▼
       copy-snapshot to us-east-2 on the LZA EBS key
       snap-0efe6b4cc20a89cb0 (200) + snap-00116924c493859fe (16)
            ▼
       register-image  →  ami-07c696aab9f4b6c43   ProductCodes: null
```

The image also carries **`skip-slave-start` in `/etc/my.cnf`**, applied on the
copy rather than on the production source box — the client document commits to
changing no configuration on their servers, and editing the source would have
left a latent trap where an unrelated reboot silently stopped replication.

## Before you apply

**1. Re-verify `private_ip` is free.** The value in `terraform.tfvars` came from
a list that may be stale. A clash fails cleanly with `InvalidIPAddress.InUse`,
but it is cheaper to check:

```bash
aws ec2 describe-network-interfaces --region us-east-2 \
  --filters Name=subnet-id,Values=subnet-00d31cac6422417c4 \
  --query 'sort_by(NetworkInterfaces,&PrivateIpAddress)[].{IP:PrivateIpAddress,Desc:Description,Status:Status}' \
  --output table
```

`10.12.1.53` is reserved for the Aheeva CTI v8.6 leaf — do not take it here.

**2. Confirm the subnet is still RAM-shared to Production.** The September
incident deleted all five shared-prod subnet shares; they were restored, but
this is the exact failure that broke the cti-v7 recreate on 2026-08-08.

```bash
aws ec2 describe-subnets --region us-east-2 --subnet-ids subnet-00d31cac6422417c4 \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Free:AvailableIpAddressCount}' --output table
```

**3. Read the plan for the second volume.** This is the first multi-BDM instance
in the estate. Expect the `/dev/sdf` volume to be created by AWS from the AMI
and to appear as computed state, **not** as a separate `aws_ebs_volume`. If the
plan shows Terraform trying to create or destroy an extra volume, stop.

Expect roughly: 1 instance, 1 security group, 1 egress rule, 1 ingress rule
(3306 from `10.12.0.0/16`), plus the KMS data source. **Nothing destroyed.**

## After you apply

The instance will **not** appear in SSM — no agent on CentOS 7, and three
previous migrated boxes arrived the same way. Do not treat that as a failure.

```bash
# 1. It booted at all
aws ec2 describe-instance-status --region us-east-2 \
  --instance-ids <id> --query 'InstanceStatuses[].{Inst:InstanceStatus.Status,Sys:SystemStatus.Status}' --output table

# 2. Both volumes attached
aws ec2 describe-instances --region us-east-2 --instance-ids <id> \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].{Dev:DeviceName,Vol:Ebs.VolumeId}' --output table
```

Then over SSH, using `Aheeva.pem` (the key is baked into the image), from the
site VPNs or an in-VPC jump host:

```bash
cat /etc/redhat-release          # CentOS Linux release 7.9.2009 (Core)
lsblk                            # 200 GiB root + 16 GiB data
systemctl status mariadb         # or mysqld, depending on the unit name
grep -A3 '^\[mysqld\]' /etc/my.cnf   # skip-slave-start MUST be present
mysql -e "SHOW SLAVE STATUS\G"   # threads should be STOPPED, not running
```

**If `SHOW SLAVE STATUS` shows the threads running, stop immediately.** That
means `skip-slave-start` did not take effect and the box has connected to
whatever `master.info` names.

## Replication — cutover only

`master.info` captured at image time (2026-09-16 14:08 UTC):

| Field | Value |
|---|---|
| `Master_Log_File` | `dbmaster-bin.000557` |
| `Master_Log_Pos` | `650520737` |
| `Master_Host` | `10.0.1.92` (source master, private) |
| `using_gtid` | `0` — repoint with explicit file+pos, **not** `MASTER_AUTO_POSITION` |

```sql
CHANGE MASTER TO MASTER_HOST='<migrated master private IP>',
  MASTER_LOG_FILE='dbmaster-bin.000557', MASTER_LOG_POS=650520737;
START SLAVE;
SHOW SLAVE STATUS\G
```

⚠️ **`server-id=2` collides with the still-running source slave.** Do not
`START SLAVE` here while the source replica is also replicating from the same
master.

⚠️ **The replication credential in `master.info` is plaintext and trivially weak
(password equals username).** It was exposed in a terminal session. Rotate at
cutover.

## Encoded gotchas

- **`db_client_cidrs` and `admin_ssh_cidrs` are APPEND-ONLY.** The module keys
  security-group rules by list index, so inserting renumbers every later rule
  into a destroy+create, which the CI destroy guard blocks on merge. Admin SSH
  is ordered first because the DB client list is the one expected to grow —
  appending to `db_client_cidrs` is therefore free.

  **But adding the first `admin_ssh_cidrs` entry is NOT free.** With the list
  empty today, the DB rule sits at index 0 and its key is
  `"3306-3306-tcp-0"`. Adding one admin SSH CIDR puts it at index 0 and shifts
  the DB rule to `"3306-3306-tcp-1"` — a destroy+create, which the guard will
  block.

  That is safe to authorise: recreating a security-group rule is a
  sub-second operation on a replica nothing depends on yet. When it happens,
  **first confirm the plan replaces only security-group rules and never the
  instance**, then add to the PR description:

  ```
  ALLOW-DESTROY: terraform/live/production/aheeva-db-slave-v86
  ```

  If the plan shows `aws_instance.this` being replaced, something else is wrong
  — stop and find out what.
- **The module only honours `cidr_blocks[0]`** per rule, so the leaf flattens
  one rule object per CIDR.
- **`additional_ebs_volumes` is deliberately empty.** The AMI declares both
  BDMs; declaring the second volume here as well collides at the same device
  name.
- **`allocate_eip` must stay `false` on this module until PR #93 merges.**
  `associate_public_ip_address` is hardcoded `false`, so `allocate_eip = true`
  produces a permanent forced replacement — the drift that destroyed cti-v7 on
  2026-08-08 when a `terraform/modules/**` change fanned an apply out to all 23
  leaves. The replica needs no EIP, so this leaf is unaffected.
- **`BackupPlan = Daily`** is the compensating control for the module's
  hardcoded `root_block_device.delete_on_termination = true`, which the leaf
  cannot override. cti-v7's root volume — and the `sip.conf` work on it — was
  lost precisely because it had neither. **This is the first EC2 leaf in the
  repo to carry the tag, so verify a recovery point actually appears** in the
  `AWSAccelerator-BackupVault` within 24 hours; the org backup policy must be
  attached to Production for the tag to do anything.
- **`monitoring = false`** — `ec2:MonitorInstances` is not in the
  TerraformExecution allow-policy.
- **Setting `key_name` later forces instance replacement.** Decide before this
  box goes into service, not at cutover.

## Rollback

The source instance `i-05b16ebe4f90c2c03` is untouched and still replicating —
verified healthy (`Seconds_Behind_Master: 0`) after the image was taken. Nothing
in this leaf affects it. Rollback is `terraform destroy` on this leaf, or simply
not cutting over.
