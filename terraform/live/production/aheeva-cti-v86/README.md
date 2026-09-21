# Aheeva CTI v8.6 — Production / shared-prod

Application server and MariaDB **master** for the Aheeva v8.6 platform, migrated
out of the source tenant. Public-facing SIP endpoint with a directly-attached
Elastic IP.

| | |
|---|---|
| **Source** | `i-085b1b072af56e661` — 254422596287 / us-east-1, private `10.0.1.92`, EIP `3.217.85.105` |
| **Destination** | Production `395516496764` / us-east-2, `shared-prod-public-a`, private `10.12.0.196` |
| **AMI** | `ami-006fd30030ba73053` — `ProductCodes: null` (verified) |
| **OS / DB** | CentOS 7.9.2009 / **MariaDB** (not MySQL) |
| **Size** | `c5.2xlarge`, matching source |
| **Disks** | `/dev/sda1` 185 GiB + `/dev/sdb` 8 GiB, both from the AMI |
| **Replica** | `aheeva-db-slave-v86` — `i-034a56060c27f95fb` at `10.12.1.54` |
| **Full procedure** | `docs/07-Operations/aheeva-v86-dd-migration-runbook.md` |

---

## 🛑 Three prerequisites before this can apply

### 1. PR #93 must be merged

`terraform/modules/ec2-migrated/main.tf` hardcodes `associate_public_ip_address = false`.
With `allocate_eip = true` that produces a **permanent forced replacement** — the
drift that destroyed cti-v7 (`i-04dc1a79b8277f654`) on 2026-08-08, when merging
an unrelated `terraform/modules/**` change fanned an apply across all leaves and
executed it.

> **⚠️ The plan on this leaf's own PR cannot reveal the problem.** Nothing is in
> state yet, so every resource shows as a clean create. The forced replacement
> only appears on the *next* plan, after apply. **Do not read a clean plan here
> as evidence that #93 is unnecessary.**

### 2. SCP carve-out for `Migrated = AheevaCTIV86`

`ec2:AllocateAddress` and `ec2:AssociateAddress` are denied in Workloads accounts
except for resources carrying an exempt tag, and today only `CTIv7` is exempt.
Reusing that value is explicitly warned against in the cti-v7 leaf, because a
second instance carrying it would silently widen that exception.

Edit `aws-accelerator-config/service-control-policies/lza-core-workloads-guardrails-1.json`,
in **both** statements:

```diff
 "Sid": "GRNETSEC2EIPAllocate",
     "StringNotEquals": {
-      "aws:RequestTag/Migrated": "CTIv7"
+      "aws:RequestTag/Migrated": ["CTIv7", "AheevaCTIV86"]
     }

 "Sid": "GRNETSEC2EIPAssociate",
     "StringNotEquals": {
-      "aws:ResourceTag/Migrated": "CTIv7"
+      "aws:ResourceTag/Migrated": ["CTIv7", "AheevaCTIV86"]
     }
```

`StringNotEquals` with a list denies unless the tag matches **any** listed value,
which is the semantics wanted.

Note `GRNETSEC2EIPAllocate` keys on `aws:RequestTag`, so the tag must be present
**at creation** — this leaf passes it through `module.tags`, which the module
merges onto the EIP.

This ships via the **hand-built config zip plus an LZA pipeline run**, not by
merging to `main`. Build the zip from a clean extract of `insight-remote/main`,
never from a working tree — see `.kiro/steering/lza-config-zip-delivery.md` and
the September incident journal. Batch it with any other pending SCP or
allow-policy edits so one pipeline run does the lot.

### 3. VPC Block Public Access exclusion

`subnet-08ce7fb6c30eed107` needs a runtime BPA exclusion. This is a separate
action from the SCP — it is not in the config zip. See
`docs/07-Operations/cti-v7-lza-exception.md`.

---

## Why this box needs a directly-attached public IP

`/etc/asterisk/sip.conf` on the migrated disk contains, verbatim:

```
externip=3.217.85.105
localnet=10.0.1.0/255.255.255.0
```

The box advertises its own public address in SIP/SDP and RTP media terminates
directly on it with no SBC. It cannot sit behind NAT or an NLB the way the SFTP
and webapp migrations do. An NLB is also ruled out on mechanics: one listener per
port against a default quota of 50 versus ~10,000 RTP ports, two public IPs where
SIP can advertise only one, and mandatory `preserve_client_ip = false`
cross-VPC over TGW which would break IP-based peer auth.

Both values must be rewritten **in-box** at cutover — `externip` to the new EIP,
`localnet` to `10.12.0.192/27`.

## Licensing — easier than cti-v7

This box is **not** host-fingerprint licensed. It performs an IP-based round-trip
handshake with Aheeva's own licence server. There is no local `.lic` file and no
local RLM server; the `/etc/logrotate.d/aheeva-licenseserver-logs` entry that
references `rlm.log` is boilerplate from the client-side package.

cti-v7 has been parked since July because its RLM licence is locked to the ENI
MAC (`rlmhostid 02417393bdd5`). Nothing here is MAC-bound, so **no reissue is
needed** — only an allowlist update.

**Ask Aheeva to allowlist the new EIP on TCP 5053 and 50555** as soon as it
exists. Same vendor contact as cti-v7.

> **⚠️ Do not lock this instance's egress.** An earlier draft of the migration
> plan proposed no-internet-egress as a safety belt against the replica's
> `skip-slave-start` hazard. That belt applies to the **replica only** — on this
> box it would break the licence handshake. Because the EIP is directly attached,
> outbound traffic sources from the EIP rather than the egress NAT gateways, so
> the single address given to Aheeva covers both directions.

---

## Before you apply

**1. Re-verify `10.12.0.196` is free.** The `/27` has only 27 usable addresses
(AWS reserves `.192`-`.195` and `.223`) and it is shared with the cti-v7 leaf,
which does **not** pin an address — so cti-v7 could take this one if it applies
first.

```bash
aws ec2 describe-network-interfaces --region us-east-2 \
  --filters Name=subnet-id,Values=subnet-08ce7fb6c30eed107 \
  --query 'NetworkInterfaces[].{IP:PrivateIpAddress,Desc:Description,Attached:Attachment.InstanceId}' \
  --output table
```

**2. Confirm the public route table still routes to the IGW.** The IGW id changed
during the September restore — `igw-0e732e2a82da6dc5a` is current and
`igw-010871f4083a631af` in older notes is stale.

```bash
aws ec2 describe-route-tables --region us-east-2 \
  --filters Name=association.subnet-id,Values=subnet-08ce7fb6c30eed107 \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,GW:GatewayId,TGW:TransitGatewayId}' --output table
```

Want `0.0.0.0/0 -> igw-…` and `10.0.0.0/8 -> tgw-0360ed77a03707835`.

**3. Read the plan for the second volume.** Expect `/dev/sdb` to appear as
computed instance state, **not** a separate `aws_ebs_volume`. Proven on the
replica, where `/dev/sdf` attached exactly this way — but confirm rather than
assume.

**4. Expect SIP ingress to be absent.** `sip_peer_cidrs` is empty on purpose. The
plan should show admin rules, RTP rules only if `rtp_extra_cidrs` is set, and one
3306 rule. That is a correct box-not-in-service state.

## After you apply

```bash
aws ec2 describe-instances --region us-east-2 --instance-ids <id> \
  --query 'Reservations[].Instances[].{State:State.Name,Priv:PrivateIpAddress,Pub:PublicIpAddress,Vols:BlockDeviceMappings[].{Dev:DeviceName,Vol:Ebs.VolumeId}}' --output json
```

Then, over SSH with `Aheeva.pem` — no SSM agent, same as every migrated box here:

```bash
cat /etc/redhat-release
lsblk                                    # 185 GiB root + 8 GiB data
systemctl status mariadb
mysql -e "SHOW MASTER STATUS\G"          # should be logging binlogs
ls -la /usr/local/AheevaCustomServer/bin/
systemctl status aheeva-pbxproxy aheeva-router aheeva-msg-center
grep -E 'externip|localnet' /etc/asterisk/sip.conf   # STILL THE OLD VALUES
```

The last line should show the **old** `3.217.85.105`. Rewriting it is a cutover
step, not a post-apply step — doing it early breaks nothing but proves nothing
either, since no peer is sending traffic yet.

**Take the EIP from the `public_ip` output and send it to Aheeva immediately**;
their allowlist update is vendor lead time.

## Encoded gotchas

- **`allocate_eip = true` requires PR #93.** See prerequisite 1, and note the
  plan here cannot show the problem.
- **`Migrated = AheevaCTIV86` must match the SCP exactly.** Deliberately not
  `CTIv7`. The questionnaire speculatively wrote `AheevaCTI-V86` with a hyphen;
  the value used here and in the SCP edit is **`AheevaCTIV86`**, no hyphen,
  matching the `CTIv7` style.
- **Rule order is load-bearing.** The module keys SG rules by list index, so
  lists are ordered `admin` → `sip` → `rtp` → `db`. Populating `sip_peer_cidrs`
  renumbers `rtp` and `db`; do it before the box carries traffic and authorise
  with `ALLOW-DESTROY: terraform/live/production/aheeva-cti-v86`. Appending to
  `db_client_cidrs` is free because it is last.
- **The module only honours `cidr_blocks[0]`**, so rules are flattened one object
  per CIDR.
- **`additional_ebs_volumes` is deliberately empty.** The AMI declares both BDMs.
- **`BackupPlan = Daily`** compensates for the module's hardcoded
  `root_block_device.delete_on_termination = true`, which the leaf cannot
  override. cti-v7 lost its root volume, and the `externip` edit on it, for
  exactly this reason.
- **`monitoring = false`** — `ec2:MonitorInstances` is absent from the
  TerraformExecution allow-policy.
- **Narrowing the RTP range requires editing `rtp.conf` in-box too.** The SG and
  the application must agree, or media breaks on calls above the narrowed
  ceiling. cti-v7 narrowed both to `10000-11000`.
- **Setting `key_name` later forces instance replacement.**

## Cutover dependencies

- **Aheeva allowlists the new EIP** (TCP 5053, 50555).
- **Every SIP peer allowlists the new EIP.** Questionnaire Section 5, 7+ days
  lead each.
- **`externip` and `localnet` rewritten** in `sip.conf`.
- **The replica repointed** at this box's private IP:
  `CHANGE MASTER TO MASTER_HOST='10.12.0.196', MASTER_LOG_FILE='dbmaster-bin.000557', MASTER_LOG_POS=650520737;`
  `using_gtid=0`, so explicit file and position — not `MASTER_AUTO_POSITION`.
- **`server-id` collision** — do not run the migrated pair's replication while the
  source pair is still replicating.
- **Rotate the replication credential**, which is plaintext in `master.info` and
  has the password equal to the username.

## Rollback

The source instance `i-085b1b072af56e661` is untouched and still serving. Nothing
in this leaf affects it. Rollback is `terraform destroy` on this leaf, or simply
not cutting over.
