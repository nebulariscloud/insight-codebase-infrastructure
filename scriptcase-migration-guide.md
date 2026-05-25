# Scriptcase Migration Guide

End-to-end guide for migrating the **Scriptcase php 7.3** server from the source tenant (us-east-1) to the new tenant (us-east-2, shared-prod account, behind the ingress ALB).

This guide is the template for migrating the rest of the servers. The patterns repeat - swap names and IDs.

---

## Architecture Summary

| Layer | Source | Destination |
|---|---|---|
| Account | Old tenant | shared-prod (LZA spoke) |
| Region | us-east-1 | us-east-2 |
| VPC | vpc-3be9b55d | vpc-04a8720d0ddb40713 (`AWSAccelerator-us-east-2-shared-prod`) |
| Subnet | subnet-161a1e3b (us-east-1c) | subnet-00d31cac6422417c4 (app-a, us-east-2a, 10.12.1.0/24) |
| Network exposure | Public IP (EIP 34.230.213.145) on the instance | Private only, fronted by the ingress ALB in perimeter |
| Egress | Direct via IGW | Via TGW to perimeter, then out |
| Admin access | SSH on port 22/1022 from a list of `/32`s | SSH via EC2 Instance Connect Endpoint (EICE) |
| Identity | AMI `ami-025d99a6c403294e2` | AMI `ami-0f18f64eff2113cd2` (copied + re-encrypted with LZA key) |
| Storage | One root volume, 32 GB, /dev/sda1 | Same (recreated from snapshot `snap-079e744113a388624`) |
| Instance type | t3a.small | t3a.small (unchanged) |

---

## Why the Layout Changed

The destination uses LZA's hub-and-spoke pattern, not the flat single-VPC the source used:

- **App workloads sit in private subnets** (`app-a`, `app-b`). No public IPs, no IGW route in those subnets.
- **All egress and ingress flow through the perimeter account** via Transit Gateway. Internet-bound traffic exits perimeter; internet-bound users hit the ingress ALB in perimeter.
- **No NAT and no SSM interface endpoints** in shared-prod, which is why SSM Session Manager didn't work last time. The agent had no path to register.

Three SSH options were considered:
1. SSM Session Manager - blocked by missing endpoints / NAT in shared-prod
2. Bastion host - none deployed
3. **EC2 Instance Connect Endpoint (EICE)** - chosen, no infra needed beyond the endpoint itself

---

## Prerequisites Already in Place

- [x] Source AMI shared and copied: `ami-0f18f64eff2113cd2` is `available` in us-east-2 shared-prod
- [x] Snapshot copied: `snap-079e744113a388624`, encrypted with `accelerator/ebs/default-encryption/key`
- [x] Destination VPC and subnet exist (`AWSAccelerator-us-east-2-shared-prod`)
- [x] Ingress ALB stack deployed in perimeter (`custom-stacks/ingress-alb.yaml`)
- [x] Reusable EC2 template available: `thenew-aws-accelerator-config/custom-stacks/migrated-ec2.yaml`

## Prerequisites to Create

- [ ] Key pair `scriptcase-key` in shared-prod / us-east-2 (Step 1)
- [ ] EC2 Instance Connect Endpoint in shared-prod VPC (Step 2)
- [ ] Security group for Scriptcase (created by the deploy)
- [ ] Internal Route53 record (optional, Step 7)

---

## Step 1 - Create the SSH Key Pair

Run from the **shared-prod** account in **us-east-2** CloudShell:

```bash
aws ec2 create-key-pair --region us-east-2 --key-name scriptcase-key --query 'KeyMaterial' --output text > scriptcase-key.pem && chmod 400 scriptcase-key.pem
```

This writes the private key to your CloudShell home directory.

**Immediately download it** to your local machine:
- CloudShell menu (top right) → Actions → Download file → enter `scriptcase-key.pem`
- Store it somewhere you'll keep (1Password, secure shared store, encrypted disk).
- After download, delete from CloudShell: `rm scriptcase-key.pem`

You cannot retrieve this key again. AWS only shows the private material at creation time.

Verify the key is registered:
```bash
aws ec2 describe-key-pairs --region us-east-2 --key-names scriptcase-key --output table
```

---

## Step 2 - Create the EC2 Instance Connect Endpoint

EICE gives you browser-based SSH into private instances without bastion, NAT, or public IPs. One endpoint per VPC is enough; it serves every instance in the VPC.

**Check if one already exists** in shared-prod us-east-2:
```bash
aws ec2 describe-instance-connect-endpoints --region us-east-2 --filters Name=vpc-id,Values=vpc-04a8720d0ddb40713 --query 'InstanceConnectEndpoints[].{Id:InstanceConnectEndpointId,State:State,Subnet:SubnetId}' --output table
```

**If empty**, create a security group for the endpoint, then the endpoint:

```bash
EICE_SG=$(aws ec2 create-security-group --region us-east-2 --group-name eice-shared-prod-sg --description "EC2 Instance Connect Endpoint egress" --vpc-id vpc-04a8720d0ddb40713 --query 'GroupId' --output text)
echo "EICE SG: $EICE_SG"

aws ec2 authorize-security-group-egress --region us-east-2 --group-id $EICE_SG --protocol tcp --port 22 --cidr 10.12.0.0/16

aws ec2 create-instance-connect-endpoint --region us-east-2 --subnet-id subnet-00d31cac6422417c4 --security-group-ids $EICE_SG --tag-specifications 'ResourceType=instance-connect-endpoint,Tags=[{Key=Name,Value=eice-shared-prod}]'
```

State will be `create-in-progress` for ~5 minutes; wait for `available`.

Note the **EICE endpoint's security group ID** (`$EICE_SG`). You'll reference it in the Scriptcase SG to allow inbound SSH from the endpoint.

---

## Step 3 - Confirm the Source's App-Level Details

These don't show up in `describe-instances`. Worth knowing before launch.

| What to check | Why |
|---|---|
| Is MySQL running locally on the source? | Source SG opens 3306 to specific IPs. Could mean other servers depend on this DB. |
| Is Scriptcase licensed? | If keyed to MAC, instance ID, or public IP, license breaks at cutover. |
| Hardcoded IPs in `/etc/...` | Old tenant private IPs (172.30.x.x), hostnames, or partner IPs in app config. |
| Cron jobs hitting external endpoints | Backup uploads, syncs - might still work, might not. |
| What user account owns the app | `ec2-user` / `centos` / `ubuntu` - matters for SSH later. |

You can pull the AMI's user data from the source for clues:

```bash
aws ec2 describe-instance-attribute --region us-east-1 --instance-id <source-instance-id> --attribute userData --query 'UserData.Value' --output text | base64 -d
```

Empty output = no user data. That's fine.

---

## Step 4 - Deploy the Instance + Security Group

Single CloudFormation stack. The template is `thenew-aws-accelerator-config/custom-stacks/scriptcase.yaml` - it creates the instance, the security group with the right inbound rules, and applies tags. One stack so create/delete is atomic.

The SG rules baked into the template:

| Port | Source | Purpose |
|---|---|---|
| 22 | EICE endpoint SG (parameter) | SSH from EC2 Instance Connect only |
| 80 | 10.0.0.0/20 | HTTP from the ingress ALB |
| 8091 | 10.0.0.0/20 | Scriptcase admin UI from the ingress ALB |
| 3306 | 10.12.0.0/16 | MySQL from inside shared-prod |
| outbound | 0.0.0.0/0 all | Default egress |

Run from shared-prod / us-east-2 CloudShell. The defaults match this environment, so the only required parameter override is `EiceSecurityGroupId` (from Step 2):

```bash
aws cloudformation deploy \
  --region us-east-2 \
  --stack-name scriptcase-php-73 \
  --template-file thenew-aws-accelerator-config/custom-stacks/scriptcase.yaml \
  --parameter-overrides EiceSecurityGroupId=$EICE_SG
```

Takes ~3 minutes. When it reports `CREATE_COMPLETE`, get the outputs:

```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name scriptcase-php-73 --query 'Stacks[0].Outputs' --output table
```

You'll get back the `InstanceId`, `PrivateIp` (use this in Step 6 to register with the ALB), `AvailabilityZone`, and `SecurityGroupId`.

> **Where `10.0.0.0/20` comes from**: that's the perimeter ingress VPC's CIDR in this LZA setup. Defined in `thenew-aws-accelerator-config/replacements-config.yaml` as `HomeRegionIngressCidr: "10.0.0.0/20"`, allocated to the IPAM ingress pool, and consumed by the perimeter ingress VPC in `network-config.yaml`. The ingress ALB lives inside that block, so locking 80/8091 to `10.0.0.0/20` allows the ALB and nothing else.
>
> **Reference of the CIDR slices in this org** (from `replacements-config.yaml`):
>
> | Block | CIDR | Purpose |
> |---|---|---|
> | GlobalCidr | 10.0.0.0/8 | Top-level org allocation |
> | HomeRegionRegionalCidr | 10.0.0.0/12 | All us-east-2 |
> | HomeRegionIngressCidr | **10.0.0.0/20** | **Perimeter ingress VPC (the ALB)** |
> | HomeRegionEgressCidr | 10.8.0.0/14 | Perimeter egress VPC |
> | HomeRegionProdWorkloadsCidr | 10.12.0.0/14 | All prod spokes (shared-prod 10.12.0.0/16 lives here) |

---

## Step 5 - SSH in via EICE and Validate

Once the instance is `running` and passes both status checks (~2 min), connect using EICE.

### Option A - From your local machine with AWS CLI configured

```bash
aws ec2-instance-connect ssh \
  --region us-east-2 \
  --instance-id <i-xxxxxxxxxxxxxxxxx> \
  --connection-type eice \
  --private-key-file ~/path/to/scriptcase-key.pem \
  --os-user ec2-user
```

If the OS user isn't `ec2-user`, try `centos`, `ubuntu`, or `admin`. The Scriptcase AMI is from 2017, so likely Amazon Linux 1 or 2 (`ec2-user`).

### Option B - From the AWS console

EC2 → Instances → select Scriptcase → Connect → **EC2 Instance Connect Endpoint** tab. The console handles tunneling; you still need the username right.

### Validation checklist (run inside the instance)

```bash
# OS basics
hostnamectl
uname -a
df -hT
free -h

# Networking
ip -br addr
cat /etc/resolv.conf
ss -tulpn   # what's listening - should see 80 (apache/nginx), 8091 (scriptcase), maybe 3306 (mysql)

# Services
systemctl list-units --type=service --state=running
systemctl status httpd nginx mysqld mariadb 2>/dev/null

# Logs
sudo tail -50 /var/log/messages
sudo tail -50 /var/log/httpd/error_log 2>/dev/null
sudo tail -50 /var/log/mysqld.log 2>/dev/null

# Find anything pointing at the old environment
sudo grep -rEI '172\.30\.|34\.230\.213\.145|amazonaws\.com' /etc /opt /var/www 2>/dev/null | head -50
```

That last `grep` is the one that flags hardcoded IPs / hostnames you'll need to update. Common things to fix:
- `/etc/hosts` entries pointing at old private IPs
- App config (`/var/www/html/.../config.php`) with a hardcoded DB hostname
- Cron jobs that backup to an old S3 bucket
- License files (some Scriptcase deployments are activated against a specific URL)

---

## Step 6 - Register With the Ingress ALB

Once the app is healthy on its private IP, register the instance into the ingress ALB target group so external users can reach it.

Run in the **perimeter** account, us-east-2:

```bash
TG_ARN=$(aws elbv2 describe-target-groups --region us-east-2 --names AWSAccelerator-ingress-alb-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
INSTANCE_PRIVATE_IP=<10.12.1.x from Step 4 outputs>
TARGET_PORT=8091   # or 80, depending on how Scriptcase serves traffic

aws elbv2 register-targets --region us-east-2 --target-group-arn $TG_ARN --targets Id=$INSTANCE_PRIVATE_IP,Port=$TARGET_PORT
```

The ALB target group was created with `TargetType=ip` so cross-account / cross-VPC IP targets work over the TGW.

Watch health:
```bash
aws elbv2 describe-target-health --region us-east-2 --target-group-arn $TG_ARN --output table
```

`healthy` means the ALB can reach Scriptcase and the health check matches. If `unhealthy` with reason `Target.FailedHealthChecks`, check:
- The ingress ALB SG egress allows the target port to `10.12.0.0/14` (already in the template)
- The Scriptcase SG inbound on the target port from `10.0.0.0/8` (or perimeter VPC CIDR)
- The app actually listens on the port (`ss -tulpn` inside the instance)
- The health check path returns the expected status code (Scriptcase's `/health` may not exist; the ingress ALB stack defaults to matcher `200,302,401`)

---

## Step 7 - DNS

If users hit Scriptcase by hostname today, repoint that hostname to the ingress ALB's DNS name in the destination's hosted zone.

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --region us-east-2 --names ingress-alb --query 'LoadBalancers[0].DNSName' --output text)
echo "Update DNS to point at: $ALB_DNS"
```

Update via Route53 (CNAME or alias to the ALB) or your external DNS provider. TTL low (60s) during cutover.

---

## Step 8 - Cutover Checklist

- [ ] App pages load via the ALB DNS name on port 80/443
- [ ] Login works
- [ ] App can talk to its database (whether local MySQL or remote)
- [ ] License is valid (Scriptcase admin UI shows no warnings)
- [ ] Scheduled jobs run without errors
- [ ] DNS updated to the ALB
- [ ] Source instance traffic stopped (check VPC flow logs in source)
- [ ] Source instance shut down (don't terminate yet - keep as fallback for 1 week)
- [ ] Document what you changed inside the OS so the runbook reflects reality

---

## Rollback

If migration fails badly, the source instance is still running and the source EIP still points to it. Revert DNS to the source. Investigate the destination instance, fix, and retry.

To wipe the destination instance entirely:
```bash
aws cloudformation delete-stack --region us-east-2 --stack-name scriptcase-php-73
```

That removes the instance and its security group together. The AMI and snapshot stay - you can redeploy any time.

---

## Things This Guide Skipped (and Why)

- **SSM-based access**: shared-prod has no NAT and no SSM interface endpoints, so the agent can't register. Adding SSM endpoints (`com.amazonaws.us-east-2.ssm`, `ssmmessages`, `ec2messages`) would fix it but EICE is faster to set up and equally good.
- **Verbatim source SG rules**: source SG had legacy rules dating back to 2017 (Aheeva, Andres, AT&T, Claro, Altice IPs etc). Most are stale. Trimmed instead.
- **EIP migration**: source has `eipalloc-062dec71a2c205911`. Can't move EIPs across regions; we put Scriptcase behind the ALB instead.
- **Cross-account SG references**: would let us reference the ingress ALB SG by ID, but requires the SG to be shared via RAM. Locking inbound to `10.0.0.0/20` (the perimeter ingress VPC CIDR) gives the same effect with less ceremony.

---

## Next Servers

Same flow applies for the rest. Differences to watch for:

| Server | Likely complications |
|---|---|
| Aheeva DB v8 1 / v8 2 | Static IP, hardcoded in app servers. Pin `PrivateIp` parameter. |
| Aheeva v8 (app) | Multiple data volumes? Check source `BlockDeviceMappings`. License likely keyed to instance. |
| Aheeva Asterisk v8 1/2/3 | SIP needs UDP ports open. SG strategy different. License keyed. |
| Alfresco | Probably the simplest after Scriptcase - one volume, web app. |

When ready, copy this guide, swap names/IDs, and run.
