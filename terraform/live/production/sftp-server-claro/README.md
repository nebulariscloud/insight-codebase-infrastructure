# SFTP server - Claro (Production / shared-prod)

Second SFTP server lift-and-shift, identical pattern to the existing
[`sftp-server`](../sftp-server/) leaf. The AMI was copied + re-encrypted
into us-east-2 ahead of time; this leaf just launches it.

The internet-facing piece (NLB) lives in the sibling leaf
[`terraform/live/perimeter/sftp-claro-nlb/`](../../perimeter/sftp-claro-nlb/).
Run this stack first, copy the `private_ip` output into that stack's
tfvars, then apply it.

The S3 bucket this server writes recordings to lives in the sibling leaf
[`terraform/live/production/claro-recordings/`](../claro-recordings/).
Apply that one **before** this stack so the scoped instance policy
resolves to a bucket that already exists. Same pattern as
`amex-recordings` -> `sftp-server`.

## AMI / snapshot provenance

| | Source (us-east-1, acct 254422596287) | Target (us-east-2, acct 395516496764) |
|---|---|---|
| AMI | `ami-08a70ee672a3be576` | `ami-02720404eb5b85c63` |
| Backing snapshot | `snap-0f0ec998581c40ad1` (unencrypted) | `snap-04370f749b46cef5c` (encrypted with `alias/accelerator/ebs/default-encryption/key`) |
| Root device | `/dev/sda1`, 20 GiB | `/dev/sda1`, 20 GiB, gp3 |

If the source ever pushes a refreshed image, follow the "Refresh
procedure" section in `scriptcase-migration-guide.md` - flow is identical,
swap the IDs.

## What this owns

- One EC2 instance from the migrated AMI (private only, no public IP).
- Instance security group allowing SFTP only from the perimeter ingress
  VPC CIDR (default `10.0.0.0/20`).
- Optional admin-SSH ingress rule from the EICE endpoint SG.
- Dedicated IAM role + instance profile (`sftp-server-claro-instance-role`)
  with SSM Session Manager, CloudWatch Agent, and a tightly-scoped
  read/write policy on the `claro-recordings` bucket. Defined in
  `iam.tf`.

## What this does NOT own

- The shared-prod VPC and subnets (LZA owns them).
- The NLB or any internet-facing piece (sibling leaf).
- The `claro-recordings` S3 bucket itself (sibling leaf).
- Route53 DNS (separate concern).
- The AMI / snapshot copy (already done out-of-band, see provenance above).

## First-time apply

```bash
cd terraform/live/production/sftp-server-claro
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

# Inside:
sudo systemctl status sshd        # SFTP listener
sudo lsof -nP -i :22              # confirm sshd on 22
df -hT                            # confirm root mounted
sudo tail -50 /var/log/sftp-bootstrap.log   # first-boot script result
```

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
# Paste into terraform/live/perimeter/sftp-claro-nlb/terraform.tfvars
# under sftp_server_private_ip. Already pinned to 10.12.1.51 here.
```

## Common gotchas

- Same as the original sftp-server leaf - see that README for the AMI
  not-found, snapshot region, and AZ-pin issues. The cause/fix are
  identical when they hit.

