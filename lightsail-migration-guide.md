# Lightsail Migration Guide

End-to-end guide for migrating Lightsail instances from the source tenant (`us-east-1`, Virginia, Zone A) into the new tenant (`us-east-2`, **shared-prod** account, behind the perimeter ingress ALB).

This guide mirrors the structure of `scriptcase-migration-guide.md` and reuses `aws-accelerator-config/custom-stacks/migrated-ec2.yaml` so we don't duplicate templates per server.

---

## Server Inventory

| # | Source name | RAM | vCPU | Disk | Source public IP | Source IPv6 | Target type | Target subnet | Migration order |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `IT-Moodle-LAMP_PHP_8-3-16` | 2 GB | 2 | 60 GB | `54.165.163.95` | `2600:1f10:4ca0:b000:3cb2:7ca3:184d:1da9` | `t3a.small` | `shared-prod-app-a` | **First (and only, for now)** |
| 2 | `Ubuntu-n8n-20251121` | 4 GB | 2 | 80 GB | `52.200.31.137` | — | `t3a.medium` | `shared-prod-app-a` | Deferred |
| 3 | `osticket1` | 512 MB | 2 | 20 GB | **`54.84.28.176`** (was recorded as `204.236.253.33` — wrong) | — | `t3a.micro` | `shared-prod-app-a` | **Migrated 2026-08-07** |

> ✅ **Corrected 2026-08-07.** This row previously read `204.236.253.33`, which is not
> `osticket1`'s address and appears nowhere in the source environment. `54.84.28.176`
> is confirmed three independent ways: the live DNS record
> `osticket.insightgrouppr.com` resolves to it; the source RDS security group
> `sg-3003a540` allows it on 3306 with the client's own description `osticket`; and the
> MySQL account osTicket authenticates with is scoped to exactly that host
> (`osticket_user@54.84.28.176`, the only row for that user). The AMI provenance is
> unaffected — the right instance was exported.
>
> **Lesson for the next server in this table:** record the Lightsail public IP *and*
> whether it is static, and re-verify it against something live (DNS, a security group
> description, a database grant) before acting on it. A single-sourced IP in an
> inventory taken weeks before the migration is not a fact. And if the address is
> dynamic, treat the instance as do-not-stop until cutover — every downstream
> allowlist, DNS record and IP-pinned database grant breaks silently when it rotates.

> **Not migrating:** `Node-js-sandbox` (`54.152.12.176`) — confirmed not in scope.

> **Sizing notes:**
> - `t3a.micro` (1 GB / 2 vCPU) is used for the 512 MB Lightsail plans. `t3a.nano` matches RAM exactly but adds zero headroom and the price difference is trivial.
> - All instances use `gp3` for the root volume regardless of source size — better baseline IOPS than the Lightsail SSD at the same or lower cost.
> - All run in AZ `us-east-2a` (`shared-prod-app-a`) for the initial migration. AZ `b` is available if HA is added later.

---

## Architecture Summary

| Layer | Source (Lightsail, us-east-1) | Destination (LZA, us-east-2) |
|---|---|---|
| Account | Source tenant Lightsail | `shared-prod` (LZA spoke, subnets shared from Network) |
| Region | us-east-1 | us-east-2 |
| VPC | AWS-managed Lightsail VPC (opaque) | `AWSAccelerator-us-east-2-shared-prod` |
| Subnet | n/a | `shared-prod-app-a` (us-east-2a) |
| Network exposure | Lightsail static IP on the instance | Private only, fronted by the perimeter ingress ALB |
| Egress | Lightsail-managed default | TGW → Egress VPC → Egress NAT Gateway → IGW (already in place) |
| Admin access | SSH from `0.0.0.0/0` (or Lightsail Firewall list) | **SSM Session Manager** via the central interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) over TGW. No SSH key, no public IP, no EICE. |
| Identity | Lightsail blueprint | EC2 AMI (exported from Lightsail snapshot, re-encrypted with LZA key) |
| Storage | Lightsail SSD | EBS gp3, encrypted with `accelerator/ebs/default-encryption/key` |
| Public IP | Lightsail static IP (not transferable) | None on the instance. Inbound = ingress ALB. Outbound = egress NAT GW EIP. |

---

## Why the Layout Changes

Lightsail isn't a peer to EC2:

- Each Lightsail instance lives in an **AWS-managed Lightsail VPC** that you can't attach to your TGW, can't peer with the perimeter VPCs, and can't see in flow logs.
- **Lightsail static IPs do not transfer** to EC2. They're a Lightsail-only construct. If a third party allowlists one of these IPs today, the allowlist breaks at cutover. Plan replacement IPs:
  - **Inbound** clients → allowlist the perimeter ingress ALB DNS (or its public IP if a CNAME isn't acceptable).
  - **Outbound** integrations (n8n webhooks, Moodle external services) → allowlist the **egress NAT Gateway EIPs** in the perimeter Egress VPC.
- The Lightsail Firewall is replaced by a per-server EC2 security group plus the ingress ALB's WAF/SG.
- Internet access in the destination is **already configured** — `shared-prod-app-*` route tables have `0.0.0.0/0` pointed at the TGW (`network-config.yaml`, lines around `shared-prod-rt-app-a`), and the central egress VPC NATs out via the perimeter IGW. **No per-server changes required for outbound internet.**

---

## Inbound Access Strategy (per server)

All three remaining apps reach the public via the perimeter ingress ALB:

| # | Server | App port | TLS termination | Suggested DNS |
|---|---|---|---|---|
| 1 | Moodle | 80 (Apache) | At the ALB | `moodle.<corp>.com` → ingress ALB |
| 2 | n8n | 5678 (default) — confirm before cutover | At the ALB | `n8n.<corp>.com` → ingress ALB |
| 3 | osTicket | 80 (Apache) | At the ALB | `tickets.<corp>.com` → ingress ALB |

Each server registers as an **IP target** in an ingress ALB target group (the target group already supports cross-account/VPC IP targets via the TGW). Add a listener rule per host header on the ALB.

If cleanly separating apps is preferred, create one target group per app and route by host header on the existing ingress ALB listener — same pattern as Scriptcase.

---

## Prerequisites Already in Place

- [x] `shared-prod` VPC and `shared-prod-app-a/b` subnets exist
- [x] TGW route from `shared-prod` to perimeter Egress VPC for `0.0.0.0/0`
- [x] Perimeter ingress ALB (`custom-stacks/ingress-alb.yaml`)
- [x] Reusable EC2 template: `aws-accelerator-config/custom-stacks/migrated-ec2.yaml`
- [x] LZA-managed KMS key alias `accelerator/ebs/default-encryption/key` in us-east-2
- [x] **Centralized SSM/SSMMessages/EC2Messages interface endpoints** in the Network endpoints VPC (`network-config.yaml` → `interfaceEndpoints.central: true`). LZA auto-creates Route53 PHZs for these and associates them with every spoke, so `shared-prod` resolves SSM hostnames via the central endpoints over TGW. No per-account endpoints required.
- [x] **`EC2-Default-SSM-Role` instance profile** defined in `iam-config.yaml`. Provides `AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy`, and the `Default-SSM-S3-Policy` for SSM agent updates and patch baselines.

## Prerequisites to Create (once, shared by all servers)

- [ ] Per-app target group on the perimeter ingress ALB (Step 7)
- [ ] DNS records pointing to the ingress ALB for each app (Step 8)

> No SSH key pair, no EC2 Instance Connect Endpoint, no per-account VPC endpoints. SSM Session Manager handles all admin access.

---

## Step 1 — Confirm SSM Reachability From `shared-prod`

LZA's central interface endpoints (defined in `network-config.yaml`) are auto-associated with every spoke VPC via Route53 PHZs. Confirm they're up:

```bash
# In the Network account, us-east-2 - list the central interface endpoints
aws ec2 describe-vpc-endpoints --region us-east-2 --filters "Name=service-name,Values=com.amazonaws.us-east-2.ssm,com.amazonaws.us-east-2.ssmmessages,com.amazonaws.us-east-2.ec2messages" --query 'VpcEndpoints[].{Service:ServiceName,State:State,VpcId:VpcId}' --output table
```

All three should be `available` and pinned to the central endpoints VPC.

```bash
# In shared-prod (Network account, us-east-2) - confirm the PHZs are associated
aws route53 list-hosted-zones-by-vpc --region us-east-2 --vpc-id vpc-04a8720d0ddb40713 --vpc-region us-east-2 --query 'HostedZoneSummaries[?contains(Name, `ssm`) || contains(Name, `ec2messages`)].Name' --output table
```

You should see private hosted zones for `ssm.us-east-2.amazonaws.com.`, `ssmmessages.us-east-2.amazonaws.com.`, and `ec2messages.us-east-2.amazonaws.com.`. If any are missing, run the LZA pipeline once with no config changes — that re-runs the PHZ association.

> If the PHZs are present and the endpoints are healthy, **the only thing needed on the instance side is the SSM agent + the `EC2-Default-SSM-Role` instance profile**. No NAT, no per-account endpoints, no key pair.

---

## Step 2 — Capture App-Level Details (Pre-Snapshot)

For Moodle, the snapshot carries everything on disk. The only things genuinely useful to know **before** the snapshot are the items that aren't on disk or that you'll need to plug into the SG / ALB / DNS at deploy time. Everything else can be inspected post-deploy via SSM.

For `IT-Moodle-LAMP_PHP_8-3-16`, ask the app owner / operator:

- [ ] **Hostname users hit today.** Maps to the new `moodle.<corp>.com` DNS record.
- [ ] **External integrations** that webhook *into* Moodle or that allowlist its current public IP (`54.165.163.95`). The snapshot doesn't know about these.
- [ ] **Any non-default listener port?** Bitnami LAMP defaults to 80 over HTTP; some installs front it with Apache on 8080 or a custom port. Confirm before writing the SG/target group.
- [ ] **Any custom plugins** that talk to external APIs or hardcode IPv6. Determines what to test during cutover.

You don't need to log into the Lightsail box for any of this if the owner can answer those four questions. If they can't, a 5-minute SSH session on the source to confirm port + grep `config.php` is enough — no exhaustive pre-flight needed.

Pull the instance's Lightsail metadata for the record:
```bash
aws lightsail get-instance --region us-east-1 --instance-name IT-Moodle-LAMP_PHP_8-3-16 --query 'instance.{Bp:blueprintId,Bn:blueprintName,Bun:bundleId,Tags:tags,UserData:userData}'
```

> **For the deferred servers (n8n, osticket1) when you migrate them:**
> - **n8n**: capture `N8N_ENCRYPTION_KEY` from `~/.n8n/config` out-of-band before snapshotting. The snapshot has it, but losing it (e.g., accidental rotation in the destination) makes every stored credential unrecoverable. Knowing the value out-of-band is the safety net.
> - **osticket1**: standard LAMP-style. `config.php` `URL` to update at cutover.

---

## Step 3 — Export Lightsail Snapshot to EC2 (Source Tenant)

Per server. The export flow:

1. Snapshot the Lightsail instance.
2. Export the snapshot — Lightsail copies it into **the same Lightsail account's EC2** as a standard EBS snapshot + AMI in `us-east-1`.
3. From there it's a regular cross-account, cross-region copy (Step 4).

Run in the **source tenant** (the one that owns the Lightsail instances):

```bash
# 4a. Take a fresh snapshot
aws lightsail create-instance-snapshot --region us-east-1 --instance-snapshot-name <server>-export-1 --instance-name <lightsail-instance-name>
```

Wait for `state: available`:
```bash
aws lightsail get-instance-snapshot --region us-east-1 --instance-snapshot-name <server>-export-1 --query 'instanceSnapshot.{State:state,SizeInGb:sizeInGb}'
```

```bash
# 4b. Export to EC2
aws lightsail export-snapshot --region us-east-1 --source-snapshot-name <server>-export-1
```

```bash
# 4c. Watch the export and grab the resulting EC2 AMI/snapshot IDs
aws lightsail get-export-snapshot-records --region us-east-1 --query 'exportSnapshotRecords[?sourceSnapshot.name==`<server>-export-1`].{State:state,Resource:resourceType,SourceArn:sourceArn,TargetIds:destinationInfo}' --output table
```

When complete, the response includes the **EC2 AMI ID** (in source-tenant EC2, us-east-1) and the **EBS snapshot ID** behind it. Record both.

> Allow 15–60 minutes per server depending on disk size. The 60 GB Moodle disk takes ~20–30 min in practice.

> The exported AMI keeps the original Lightsail blueprint's user accounts, services, and `cloud-init` configs. It boots fine in EC2, but cleanup is needed inside the OS post-launch (Step 6).

Per-server tracking:

| Server | Lightsail snapshot name | Source EC2 AMI ID | Source EC2 snapshot ID |
|---|---|---|---|
| Ubuntu-n8n-20251121 | (deferred) | (deferred) | (deferred) |
| IT-Moodle-LAMP_PHP_8-3-16 | `moodle-export-1` | `ami-xxxxxxxxxxxxxxxxx` | `snap-xxxxxxxxxxxxxxxxx` |
| osticket1 | (deferred) | (deferred) | (deferred) |

---

## Step 4 — Cross-Account Share, Cross-Region Copy, Re-Encrypt

Same procedure as `snapshot-ami-migration-guide.md`. Per server:

### 5a. In the source tenant — share with the destination account

```bash
SRC_AMI=ami-xxxxxxxxxxxxxxxxx
DEST_ACCT=395516496764   # shared-prod / Production account ID

aws ec2 modify-image-attribute --region us-east-1 --image-id $SRC_AMI --launch-permission "Add=[{UserId=$DEST_ACCT}]"
```

If you need the snapshot independently (for the root volume rebuild path), share it too:
```bash
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id <src-snap> --attribute createVolumePermission --operation-type add --user-ids $DEST_ACCT
```

> Lightsail-exported AMIs/snapshots are encrypted with the **default `aws/ebs` AWS-managed key**. AWS-managed keys can't be shared. The workaround in Part 3 of `snapshot-ami-migration-guide.md` applies: copy-snapshot to itself in the source tenant re-encrypted with a customer-managed CMK, share the CMK to the destination account, then proceed. This adds one extra `copy-snapshot` step per server in the source tenant before sharing.

### 5b. In `shared-prod` (us-east-2) — resolve the LZA EBS key once

```bash
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
echo "Target key: $TARGET_KEY_ARN"
```

### 5c. Per server — copy the AMI cross-region and re-encrypt

```bash
aws ec2 copy-image --region us-east-2 --source-region us-east-1 --source-image-id $SRC_AMI --encrypted --kms-key-id "$TARGET_KEY_ARN" --name "<server>-from-lightsail"
```

Note the new `ImageId`. Wait for `available`:
```bash
aws ec2 describe-images --region us-east-2 --image-ids <new-ami> --query "Images[0].State"
```

Capture the new backing snapshot ID for the records:
```bash
aws ec2 describe-images --region us-east-2 --image-ids <new-ami> --query "Images[0].BlockDeviceMappings[*].{Device:DeviceName,Snap:Ebs.SnapshotId,Size:Ebs.VolumeSize,Encrypted:Ebs.Encrypted}" --output table
```

Per-server tracking:

| Server | Destination AMI (us-east-2) | Destination snapshot |
|---|---|---|
| Ubuntu-n8n-20251121 | (deferred) | (deferred) |
| IT-Moodle-LAMP_PHP_8-3-16 | `ami-xxxxxxxxxxxxxxxxx` | `snap-xxxxxxxxxxxxxxxxx` |
| osticket1 | (deferred) | (deferred) |

---

## Step 5 — Deploy the Instance + SG

> **⚠️ THIS SECTION IS SUPERSEDED.** It describes the LZA `custom-stacks/migrated-ec2.yaml`
> route, which is **no longer how we deploy migrated servers.** Every box in the CTI v7
> workstream (`cti-v7`, `webapps`, `webapps-php73`, `ws-aheeva`, `iccmaindb`) was
> delivered as a **Terraform leaf under `terraform/live/production/` via a GitHub PR**,
> per `.kiro/steering/terraform-changes-via-github-pr.md`. CI applies on merge to `main`;
> there are no local applies and no LZA pipeline run for workload servers.
>
> **Do this instead:**
>
> 1. Copy an existing leaf as the template. `terraform/live/production/webapps/` is the
>    closest match for a simple private web server (private in `shared-prod-app-a`,
>    SG allowing 80/443 from the ingress VPC CIDR, `monitoring = false`, auto-resolved
>    LZA EBS key, gp3 encrypted root). `sftp-server/` is the reference if the server
>    needs its own IAM policy.
> 2. Set `ami_id` to the AMI produced in Step 4, pick a free `private_ip` in
>    `shared-prod-app-a` (**verify it is free first** — a previous migration hit
>    `InvalidIPAddress.InUse`), and size the instance per the inventory table.
> 3. Each leaf needs its own `.gitignore` containing `!terraform.tfvars`, or CI fails
>    with "Given variables file terraform.tfvars does not exist" (the root `.gitignore`
>    excludes `*.tfvars`). Copy the pattern from `sftp-server/.gitignore`.
> 4. Keep `monitoring = false` — `ec2:MonitorInstances` is absent from the
>    TerraformExecution allow-policy and the apply will fail with `UnauthorizedOperation`.
> 5. `terraform fmt -check -recursive -diff <leaf>` before committing, stage **only**
>    that leaf (`git add terraform/live/production/<leaf>/` — never `git add .`, the
>    working tree carries a lot of unrelated churn), then PR to `main` and read the plan.
>
> The rest of this section is retained for historical context only.

The reusable template (`aws-accelerator-config/custom-stacks/migrated-ec2.yaml`) handles the instance, secondary volumes, optional EIP, optional Route53 record. It does **not** create the security group — pass an existing SG ID, or create a per-server SG once and reference it.

### 5a. Per-server security group (one-time, per server)

Tight per-app SG. **No SSH inbound** — SSM Session Manager runs over outbound HTTPS to the SSM interface endpoints, no ingress port required.

```bash
SG_NAME=moodle-sg
MOODLE_SG=$(aws ec2 create-security-group --region us-east-2 --group-name $SG_NAME --description "Moodle migrated from Lightsail" --vpc-id vpc-04a8720d0ddb40713 --query 'GroupId' --output text)

# App port from perimeter ingress VPC CIDR (the only ingress the box needs)
aws ec2 authorize-security-group-ingress --region us-east-2 --group-id $MOODLE_SG --protocol tcp --port 80 --cidr 10.0.0.0/20

# Default egress is all -> 0.0.0.0/0 (already there at create time, lets the
# SSM agent reach the central interface endpoints over TGW and lets the app
# reach the internet via the perimeter NAT GW)
```

Per-server SG ports:

| Server | Inbound port from `10.0.0.0/20` (ingress VPC) | SSH inbound |
|---|---|---|
| IT-Moodle-LAMP_PHP_8-3-16 | 80 (TCP) | none |
| Ubuntu-n8n-20251121 (deferred) | 5678 (TCP) | none |
| osticket1 (deferred) | 80 (TCP) | none |

> Source: `10.0.0.0/20` = perimeter ingress VPC CIDR (`HomeRegionIngressCidr` in `replacements-config.yaml`). This locks app ports to the ingress ALB and nothing else.

### 5b. Resolve the SSM instance profile name

The instance profile `EC2-Default-SSM-Role` (defined in `iam-config.yaml`) is created in every account by LZA. Its IAM-side name is `${ACCELERATOR_PREFIX}-EC2-Default-SSM-Role` (typically `AWSAccelerator-EC2-Default-SSM-Role`). Confirm in `shared-prod`:

```bash
aws iam list-instance-profiles --query 'InstanceProfiles[?contains(InstanceProfileName, `EC2-Default-SSM-Role`)].InstanceProfileName' --output text
```

Capture the exact name (`SSM_PROFILE_NAME`) for the deploy step.

### 5c. SSM agent bootstrap user data (most Lightsail blueprints)

Lightsail Ubuntu blueprints ship the Snap-installed SSM agent disabled or stale. Bitnami LAMP blueprints often don't include it at all. The user-data block below is idempotent: if the agent is already present and up-to-date, it's a no-op; otherwise it installs and enables it.

Save this once as `ssm-bootstrap.sh`:

```bash
#!/bin/bash
set -eux

# Generic best-effort SSM agent install. Works on Ubuntu, Debian, Amazon Linux, RHEL.
REGION=$(curl -fsS http://169.254.169.254/latest/meta-data/placement/region || echo us-east-2)

if command -v snap >/dev/null 2>&1; then
  snap install amazon-ssm-agent --classic 2>/dev/null || true
  snap start amazon-ssm-agent 2>/dev/null || true
fi

if [ ! -x /usr/bin/amazon-ssm-agent ] && [ ! -x /snap/bin/amazon-ssm-agent ]; then
  if command -v dpkg >/dev/null 2>&1; then
    DEB=/tmp/amazon-ssm-agent.deb
    curl -fsSL "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/debian_amd64/amazon-ssm-agent.deb" -o "$DEB"
    dpkg -i "$DEB" || apt-get -y -f install
  elif command -v rpm >/dev/null 2>&1; then
    yum install -y "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"
  fi
fi

systemctl enable --now amazon-ssm-agent 2>/dev/null || \
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true

# Optional: CloudWatch agent (the EC2-Default-SSM-Role already has the perms)
# Leave commented unless you actually want host metrics in CloudWatch.
# yum install -y amazon-cloudwatch-agent || apt-get install -y amazon-cloudwatch-agent || true
```

Base64-encode it for the CFN parameter:

```bash
USER_DATA_B64=$(base64 -i ssm-bootstrap.sh)
```

### 5d. Deploy each instance

Pull the destination subnet ID once:
```bash
SUBNET_APP_A=$(aws ec2 describe-subnets --region us-east-2 --filters "Name=tag:Name,Values=AWSAccelerator-us-east-2-shared-prod-app-a" --query 'Subnets[0].SubnetId' --output text)
echo "$SUBNET_APP_A"
```

Then deploy Moodle:
```bash
aws cloudformation deploy \
  --region us-east-2 \
  --stack-name moodle \
  --template-file aws-accelerator-config/custom-stacks/migrated-ec2.yaml \
  --parameter-overrides \
      AmiId=<moodle-dest-ami> \
      InstanceType=t3a.small \
      SubnetId=$SUBNET_APP_A \
      SecurityGroupIds=$MOODLE_SG \
      ServerName=moodle \
      IamInstanceProfileName=$SSM_PROFILE_NAME \
      UserDataBase64=$USER_DATA_B64 \
      AllocateEip=false
```

> `KeyName` is intentionally omitted. The `migrated-ec2.yaml` template treats it as optional and skips the property when blank. No SSH key is created or attached.

When n8n and osticket1 come off the deferred list, repeat with `InstanceType=t3a.medium` (n8n) or `t3a.micro` (osticket1) and their own SG.

The template tags every instance with `Migrated=true` and `Accelerator=AWSAccelerator`, plus a `Name` tag from `ServerName`. Add `DailyBackup=True` if you want LZA's backup plan to pick the instance up automatically — adjust the template or pass through `Tags` if needed.

Get the new private IPs from the stack outputs:
```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name <stack> --query 'Stacks[0].Outputs' --output table
```

### 5e. Verify the instance registered with SSM

Wait 2–3 minutes after the instance reaches `running`, then:

```bash
aws ssm describe-instance-information --region us-east-2 --filters "Key=InstanceIds,Values=<i-xxxxxxxxxxxxxxxxx>" --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Platform:PlatformName,Agent:AgentVersion}' --output table
```

`PingStatus: Online` means the agent can reach `ssm`/`ssmmessages`/`ec2messages` through the central endpoints — you're good. If it stays `Inactive` or doesn't appear:

| Symptom | Likely cause | Fix |
|---|---|---|
| Instance not listed at all after 5 min | SSM agent didn't install | Reboot once; LZA `cloud-init` may need a kick. If still missing, the user-data didn't run — check console output. |
| `Inactive` / `Connection lost` | Agent installed, can't reach endpoints | Verify the three PHZs are associated with `shared-prod` (Step 1), and the SG egress allows `443/tcp` outbound (default `0.0.0.0/0` egress covers it). |
| `ConnectionLost` after sometime working | TGW route flapped / endpoints VPC isn't propagating | Check `endpoints` VPC TGW attachment status in Network account. |

---

## Step 6 — Connect via SSM Session Manager and Clean Up the Lightsail Cruft

Two ways to connect, both go through the central SSM endpoint over TGW. No public IP, no key file, no EICE, no VPN.

### Option A — From your local machine (AWS CLI + Session Manager plugin installed)

```bash
aws ssm start-session --region us-east-2 --target <i-xxxxxxxxxxxxxxxxx>
```

You land as `ssm-user`. Use `sudo -i` to escalate. Lightsail blueprint home directories are still under `/home/ubuntu`, `/home/bitnami`, `/home/ec2-user` — `sudo -u ubuntu -i` to drop into the original app user when working with app config files.

Install the plugin once (macOS):
```bash
brew install --cask session-manager-plugin
```

### Option B — Console

EC2 → Instances → select instance → Connect → **Session Manager** tab → Connect. Browser-based shell, same `ssm-user` identity.

### Optional — SSH-over-SSM tunnel (rarely needed)

If a tool genuinely needs an SSH connection (rsync, scp, IDE remote dev), you can layer SSH on top of SSM with a one-line `~/.ssh/config` entry:

```
Host i-* mi-*
  ProxyCommand sh -c "aws ssm start-session --region us-east-2 --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

This still requires per-instance SSH keys provisioned inside the OS. For interactive admin, prefer plain `start-session`.

### Cleanup checklist (every Lightsail-exported instance)

```bash
# 6a. Disable Lightsail firewall daemon if present
sudo systemctl list-units --type=service | grep -i lightsail
sudo systemctl disable --now lightsail-firewall.service 2>/dev/null
sudo systemctl disable --now amazon-lightsail-* 2>/dev/null

# 6b. Verify SSM agent is healthy (you're in over SSM, but worth confirming)
sudo systemctl status amazon-ssm-agent --no-pager 2>/dev/null || \
  sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service --no-pager

# 6c. Verify no Lightsail-only services are blocking boot
sudo journalctl -u cloud-init --since "10 min ago" | grep -i lightsail

# 6d. Confirm no stale Lightsail metadata calls
sudo grep -rEI 'lightsail|169.254.169.254' /etc /usr/local/bin 2>/dev/null | head -30

# 6e. Confirm internet egress works (via perimeter NAT GW)
curl -s https://checkip.amazonaws.com/   # should return the perimeter NAT GW EIP, not the old Lightsail IP
nslookup download.moodle.org             # Moodle's plugin / language pack source

# 6f. (Optional) Disable password and root SSH login since SSM is the access path
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
```

### App-specific touchups

**IT-Moodle-LAMP_PHP_8-3-16**

- Edit `/var/www/html/moodle/config.php` (Bitnami blueprint typically installs at `/opt/bitnami/moodle/htdocs/config.php` instead — check both):
  - `$CFG->wwwroot = 'https://moodle.<corp>.com';`
  - `$CFG->dataroot` should still resolve (it's a local path).
  - `$CFG->dbhost` stays `localhost` if MySQL runs on the same instance (LAMP blueprint default).
- Enable maintenance mode during cutover:
  ```bash
  sudo -u www-data php /var/www/html/moodle/admin/cli/maintenance.php --enable
  ```
- Update `wwwroot` declaratively (alternative to editing `config.php` by hand):
  ```bash
  sudo -u www-data php /var/www/html/moodle/admin/cli/cfg.php --name=wwwroot --set=https://moodle.<corp>.com
  ```
- Clear caches:
  ```bash
  sudo -u www-data php /var/www/html/moodle/admin/cli/purge_caches.php
  ```
- Disable maintenance once DNS has cut over and the ALB target is healthy:
  ```bash
  sudo -u www-data php /var/www/html/moodle/admin/cli/maintenance.php --disable
  ```
- **IPv6 sanity check.** Source had a public IPv6 (`2600:1f10:4ca0:b000:...`). Destination is IPv4 only. If any Moodle plugin or external service hardcoded IPv6, those break. Search and document:
  ```bash
  sudo grep -rEI '2600:1f10:|::1' /etc /var/www 2>/dev/null | head -20
  ```
- **Bitnami blueprint specifics** (if the source AMI is the Bitnami LAMP one, not the plain Ubuntu LAMP):
  - The web user is `daemon` on Bitnami, `www-data` on stock LAMP. Use whichever the running Apache process uses.
  - `bnconfig` and `bncert-tool` daemons exist for Bitnami's setup wizard and Let's Encrypt automation. Disable them now that TLS lives at the ALB:
    ```bash
    sudo systemctl disable --now bitnami 2>/dev/null
    ```
  - Bitnami's banner page at `/` redirects to a Bitnami status page on first hit. If users see this instead of Moodle, comment out the `/var/www/html/index.html` redirect or remove it.

**Ubuntu-n8n-20251121** *(deferred)*

When n8n is migrated:

- Update `~/.n8n/config` (or `/etc/n8n/.env`, depends on install): set `WEBHOOK_URL=https://n8n.<corp>.com/` (matches the new ALB DNS), keep `N8N_ENCRYPTION_KEY` exactly as captured in Step 2.
- If n8n was reverse-proxied behind nginx/caddy on the Lightsail box, that config still ships in the AMI. Decide: keep nginx as the local reverse proxy on `:80`, or strip it and let the ALB hit n8n directly on `:5678`. The cleaner option is to point the ALB target group at `:5678` and leave the local nginx alone or remove it.
- Restart: `sudo systemctl restart n8n`.
- Inventory the active credentials in the n8n UI and rotate any IP-allowlisted ones. Old Lightsail IP `52.200.31.137` is no longer the source IP of outbound calls — the perimeter NAT GW EIP is.

**osticket1** *(deferred)*

Standard LAMP flow when ready: snapshot → export → share → copy → deploy → cleanup. osTicket's `config.php` has a `URL` value to update, plus an installer-time `host` value in `ost-config.php`.

---

## Step 7 — Register Each Instance With the Perimeter Ingress ALB

In the **perimeter** (`Network`) account, us-east-2:

```bash
# Find or create the per-app target group
aws elbv2 describe-target-groups --region us-east-2 --query 'TargetGroups[].TargetGroupName' --output table
```

If a target group for the app doesn't exist, create one (per-app):
```bash
aws elbv2 create-target-group \
  --region us-east-2 \
  --name moodle-tg \
  --protocol HTTP \
  --port 80 \
  --target-type ip \
  --vpc-id <perimeter-ingress-vpc-id> \
  --health-check-path /login/index.php \
  --health-check-protocol HTTP \
  --matcher HttpCode=200,302
```

> Moodle's `/login/index.php` returns `200` (or `303`/`302` to a session URL) when healthy. The root `/` may return a redirect to `wwwroot` that fails before DNS cutover, so target a stable path for health checks.

Register the instance's private IP:
```bash
TG_ARN=$(aws elbv2 describe-target-groups --region us-east-2 --names moodle-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --region us-east-2 --target-group-arn $TG_ARN --targets Id=<moodle-private-ip>,Port=80
```

Add a host-header listener rule on the ingress ALB's HTTPS listener (priority unique per rule):
```bash
LISTENER_ARN=$(aws elbv2 describe-listeners --region us-east-2 --load-balancer-arn <ingress-alb-arn> --query 'Listeners[?Port==`443`].ListenerArn' --output text)

aws elbv2 create-rule --region us-east-2 --listener-arn $LISTENER_ARN --priority 100 --conditions 'Field=host-header,Values=moodle.<corp>.com' --actions Type=forward,TargetGroupArn=$TG_ARN
```

Repeat per app. Watch health:
```bash
aws elbv2 describe-target-health --region us-east-2 --target-group-arn $TG_ARN --output table
```

Per-server registration tracking:

| Server | Target group name | Target port | ALB rule priority | DNS hostname |
|---|---|---|---|---|
| IT-Moodle-LAMP_PHP_8-3-16 | `moodle-tg` | 80 | 100 | `moodle.<corp>.com` |
| Ubuntu-n8n-20251121 (deferred) | `n8n-tg` | 5678 | 110 | `n8n.<corp>.com` |
| osticket1 (deferred) | `osticket-tg` | 80 | 120 | `tickets.<corp>.com` |

---

## Step 8 — DNS Cutover

Ahead of cutover, drop the TTL on each record to 60s. At cutover:

1. In Route53 (or the external DNS provider), repoint each hostname to the perimeter ingress ALB's DNS name (CNAME, or A-alias if it's a Route53 zone).
2. Watch traffic shift on the ALB target group's `RequestCount` and `HealthyHostCount` metrics.
3. Once the source instance traffic drops to zero (check Lightsail's instance metrics), proceed to Step 9.

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-east-2 --names ingress-alb --query 'LoadBalancers[0].DNSName' --output text)
echo "Repoint DNS to: $ALB_DNS"
```

---

## Step 9 — Outbound Allowlist Updates

Anything that Moodle calls out to (plugin update servers, SMS/email gateways, partner APIs) that allowlisted the **old Lightsail static IP** needs updating to the new outbound IPs. Same applies for n8n and osticket1 when those are migrated:

- **New outbound IP source** = the EIPs on the perimeter Egress NAT Gateways (one per AZ). Get them once:
  ```bash
  aws ec2 describe-nat-gateways --region us-east-2 --filter "Name=tag:Name,Values=AWSAccelerator-us-east-2-egress-public-natgw-a,AWSAccelerator-us-east-2-egress-public-natgw-b" --query 'NatGateways[].{Name:Tags[?Key==`Name`].Value|[0],EIP:NatGatewayAddresses[0].PublicIp}' --output table
  ```
- Communicate the two NAT GW EIPs to:
  - Moodle plugins that call external services (SMS gateways, email relays, plugin update servers)
  - Any partner service that allowlisted the Moodle public IP
- Old Lightsail IPs to remove from any partner allowlist:
  - `54.165.163.95` (Moodle) — at cutover
  - `52.200.31.137` (n8n) — when n8n is migrated
  - `204.236.253.33` (osticket1) — when osticket1 is migrated
  - `54.152.12.176` (Node-js-sandbox) — **not migrating; instance and IP being decommissioned independently. Coordinate with the sandbox owner before removing this from any allowlist.**

---

## Step 10 — Cutover Checklist (Per Server)

- [ ] App pages load via the new DNS name on 443
- [ ] Authenticated flows work end-to-end (Moodle login round-trip)
- [ ] App can reach the internet (`curl https://checkip.amazonaws.com/` returns NAT GW EIP)
- [ ] Outbound integrations succeed (Moodle plugin update check, course backup to external S3 if configured)
- [ ] Inbound integrations updated (webhook senders pointing at the new DNS)
- [ ] Schedules / cron jobs ran successfully at least once (Moodle's cron via `/var/spool/cron/` or `/etc/cron.d/moodle`)
- [ ] No errors in `journalctl -u apache2` (or `httpd`) and `journalctl -u mysql` (or `mariadb`)
- [ ] Source Lightsail instance traffic stopped (Lightsail metrics)
- [ ] Source Lightsail instance **stopped, not deleted** — keep as fallback for 7 days
- [ ] Internal docs / runbook updated with new instance ID and DNS

---

## Rollback

If a server's migration fails after cutover:

| When | Rollback path |
|---|---|
| Before DNS cutover | Don't flip DNS. Tear down the destination stack (`aws cloudformation delete-stack`) and restart from Step 3 with whatever was wrong fixed. Source Lightsail is still serving live traffic. |
| After DNS cutover, source still up | Flip DNS back to the Lightsail static IP, drop TTL, investigate. Source Lightsail keeps serving. |
| After source Lightsail deleted | No rollback. The exported AMI in source-tenant EC2 (Step 3b output) is the only artifact. Re-deploy from the destination AMI (no traffic should be lost since the destination is the live system in this scenario). |

The Lightsail snapshot from Step 3a stays in the source tenant indefinitely (until you delete it). It's the long-term safety net — keep it for at least the agreed retention window after the source instance is deleted.

---

## Files You Will Touch

| Step | File | What changes |
|---|---|---|
| 5 (per server SG) | None — created via CLI | Per-app SG in `shared-prod` (no SSH inbound; SSM is outbound only) |
| 5 (per server stack) | `aws-accelerator-config/custom-stacks/migrated-ec2.yaml` | Already updated to make `KeyName` optional and accept the SSM instance profile + bootstrap user data. New CFN stacks per server are deployed against it. |
| 7 (ALB target groups + rules) | None — created via CLI in perimeter account | Per-app target groups and host-header rules |
| 8 (DNS) | DNS provider | Repoint hostnames at the ingress ALB |

Files **not** touched:

- No SCP changes — Lightsail is being **decommissioned**, not provisioned.
- No `network-config.yaml` changes — internet egress already configured, central SSM endpoints already exist.
- No `iam-config.yaml` changes — the `EC2-Default-SSM-Role` instance profile is already defined.
- No `customizations-config.yaml` changes (unless these stacks should be pipeline-managed instead of CLI-deployed; see "Optional: pipeline-manage these stacks" below).
- No `security-config.yaml` or `accounts-config.yaml`.

---

## Optional — Pipeline-Manage the Stacks Instead of CLI Deploy

The three Scriptcase-style stacks under `custom-stacks/` are deployed with the LZA CodePipeline via `customizations-config.yaml` entries. If you want the same for these four:

- Add `customizations.cloudFormationStacks` entries pointing at `custom-stacks/migrated-ec2.yaml` with per-server `parameters` (AMI ID, instance type, ServerName, etc.).
- `deploymentTargets.accounts: [Production]` (or whichever account owns shared-prod app workloads in your `accounts-config.yaml`).
- `regions: [{{ HomeRegion }}]`.
- Zip and run the pipeline.

This trades faster iteration (CLI deploy) for IaC consistency (pipeline-managed). For one instance now (Moodle) and two more later, CLI is fine. If the migration backlog grows, pipeline-managing becomes the right pattern.

---

## Estimated Timeline

| Phase | Duration (per server, except where noted) |
|---|---|
| Step 1 prep (one-time) | 5 min |
| Step 2 app inventory | 30 min |
| Step 3 Lightsail snapshot + export | 15–60 min (parallel-friendly) |
| Step 4 share + copy + re-encrypt | 15–30 min |
| Step 5 SG + CFN deploy | 10 min |
| Step 6 OS cleanup + app touchups | 30–60 min |
| Step 7 ALB target group + rule | 5 min |
| Step 8 DNS cutover + observation | 30 min |
| Step 9 outbound allowlist updates | varies, owner-driven |

Total active engineering time per server: **~2–3 hours**, plus async wait time on snapshots and DNS TTL.

---

## References

- AWS — Export Lightsail snapshot to Amazon EC2: https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-exporting-snapshots-to-amazon-ec2.html
- `snapshot-ami-migration-guide.md` (this repo) — KMS handling and cross-account share details
- `scriptcase-migration-guide.md` (this repo) — EICE setup, ALB target group patterns, source-tenant prep
- `eip-cross-org-migration-guide.md` (this repo) — only relevant if a Lightsail static IP must be preserved (it can't, but document is the authority on EIP transfers if needed for a different source)
- `aws-accelerator-config/custom-stacks/migrated-ec2.yaml` — reusable instance template
