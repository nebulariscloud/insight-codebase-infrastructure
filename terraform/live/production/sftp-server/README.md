# SFTP server (Production / shared-prod)

Lift-and-shift of an SFTP server from another AWS account. The AMI was
already copied into us-east-2; this leaf just launches it in shared-prod
behind LZA's existing private-only posture.

The internet-facing piece (NLB) lives in the sibling leaf
[`terraform/live/perimeter/sftp-nlb/`](../../perimeter/sftp-nlb/). Run
this stack first, copy the `private_ip` output into that stack's tfvars,
then apply it.

## What this owns

- One EC2 instance from the migrated AMI (private only, no public IP).
- Instance security group allowing SFTP only from the perimeter ingress
  VPC CIDR (default `10.0.0.0/20`).
- Optional extra data volume from a snapshot, attached at `/dev/sdb`.

## What this does NOT own

- The shared-prod VPC and subnets (LZA owns them; shared from the
  Network account into Production via RAM).
- The NLB or any internet-facing piece (sibling leaf).
- Route53 DNS (separate leaf if you want a friendly hostname).
- The AMI / snapshot copy (do that once, manually, before applying).

## Constraints baked in

- `shared-prod` has `internetGateway: false` (per LZA's
  `network-config.yaml`), so the instance has no path to the internet
  except via TGW -> egress -> NAT GW.
- The `lza-core-workloads-guardrails-1` SCP denies
  `ec2:AllocateAddress` and `ec2:AssociateAddress` for non-LZA
  principals, so EIPs are not allocated here.
- Terraform's policy denies it from touching VPCs, IGWs, NACLs, or
  shared-prod subnets. It only manages the EC2, its SG, and any extra
  EBS volumes.

## First-time apply

```bash
# 1. Confirm the AMI exists in us-east-2 in the Production account
aws ec2 describe-images --image-ids ami-0142292b2f75b5156 --region us-east-2

# 2. Look up VPC and subnet
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*shared-prod*" \
  --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table

aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
  "Name=tag:Name,Values=*shared-prod-app*" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# 3. Edit terraform.tfvars - set vpc_id, subnet_id, optionally private_ip
# 4. Apply
cd terraform/live/production/sftp-server
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan
```

## Verifying the instance

After apply, get into the box via SSM Session Manager. The instance
role carries `AmazonSSMManagedInstanceCore`, and the `user_data` in
`main.tf` installs and enables `amazon-ssm-agent` on first boot
(needed because the migrated AMI is Debian 13 / trixie which does not
ship the agent by default — see the Claro SFTP migration summary
under `docs/07-Operations/`). Within ~2 minutes of boot the agent
registers and Session Manager is available.

```bash
INSTANCE_ID=$(terraform output -raw instance_id)

# Confirm the agent has registered (PingStatus=Online).
aws ssm describe-instance-information \
  --region us-east-2 \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion,PlatformName]' \
  --output table

aws ssm start-session --target $INSTANCE_ID --region us-east-2

# Inside the session:
sudo systemctl status sshd        # SSH/SFTP listener should be running
sudo lsof -nP -i :22              # confirm sshd listening on 22
df -h                             # confirm root mounted
sudo tail -50 /var/log/sftp-bootstrap.log   # first-boot script result
```

If `df -h` doesn't show the data volume, format and mount it once:

```bash
# Inside the SSM session, only if /dev/nvme1n1 (or /dev/sdb) is unformatted
sudo file -s /dev/nvme1n1
# If output says "data" -> not yet a filesystem, run mkfs:
sudo mkfs.xfs /dev/nvme1n1
sudo mkdir -p /sftp
sudo mount /dev/nvme1n1 /sftp
echo "/dev/nvme1n1 /sftp xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

If the snapshot was already a formatted filesystem, skip the mkfs and
just mount it.

## Fallback access via EICE

If the SSM agent is offline (transient network issues, bad route, agent
crash), the instance SG also accepts inbound TCP/22 from the
shared-prod EC2 Instance Connect Endpoint SG (`sg-0a990a87e6abca926`),
wired up via `eice_security_group_id` in `terraform.tfvars`. To use it:

```bash
aws ec2-instance-connect ssh \
  --region us-east-2 \
  --instance-id $INSTANCE_ID \
  --connection-type eice \
  --os-user ec2-user
```

Useful when troubleshooting the SSM agent itself (you can `journalctl
-u amazon-ssm-agent -n 200` and check connectivity to
`ssm.us-east-2.amazonaws.com` from inside the box).

## Hand-off to the NLB leaf

```bash
terraform output -raw private_ip
# Paste this into terraform/live/perimeter/sftp-nlb/terraform.tfvars
# under sftp_server_private_ip.
```

## Common gotchas

- `ami-0142292b2f75b5156 not found`: the AMI is in another region or
  account. Run `aws ec2 describe-images --image-ids <ami>
  --region us-east-2` to confirm.
- `Snapshot snap-... not found`: the snapshot is in another region or
  account. Snapshots can be cross-account-shared but must be in the
  destination region. If you only have it in us-east-1, copy it first:
  `aws ec2 copy-snapshot --source-region us-east-1 --source-snapshot-id
  snap-... --destination-region us-east-2 --description "sftp data"`.
- `availability_zone of volume does not match instance`: the data volume
  is bound to the instance's AZ. The module already pins
  `availability_zone = aws_instance.this.availability_zone`, so this
  only happens if you're importing a pre-existing volume. Don't.
