# SFTP server - F9 (Production / shared-prod)

Third SFTP server lift-and-shift, identical pattern to the existing
[`sftp-server`](../sftp-server/) and
[`sftp-server-claro`](../sftp-server-claro/) leaves. The AMI was copied +
re-encrypted into us-east-2 ahead of time (2026-08-27); this leaf just
launches it.

The internet-facing piece (NLB) lives in the sibling leaf
[`terraform/live/perimeter/sftp-f9-nlb/`](../../perimeter/sftp-f9-nlb/).
Run this stack first, copy the `private_ip` output into that stack's
tfvars, then apply it.

The S3 bucket this server writes recordings to lives in the sibling leaf
[`terraform/live/production/f9-recordings/`](../f9-recordings/).
Apply that one **before** this stack so the scoped instance policy
resolves to a bucket that already exists. Same pattern as
`amex-recordings` -> `sftp-server` and `claro-recordings` ->
`sftp-server-claro`.

## AMI / snapshot provenance

| | Source (us-east-1, acct 254422596287) | Target (us-east-2, acct 395516496764) |
|---|---|---|
| AMI | `ami-0207938d1f8eedf49` (`f9-sftp-migration-image`) | `ami-0545c53be16039a74` (`sftp-server-f9`) |
| Backing snapshot | `snap-0a9a4f2996e6cbd07` (unencrypted) | `snap-01b7371428ef4d68f` (encrypted with `alias/accelerator/ebs/default-encryption/key`) |
| Root device | `/dev/xvda`, 20 GiB gp3 | `/dev/xvda`, 20 GiB, gp3 |
| Source instance | `i-018f8ea99b6beafab` (single attachment, `vol-034113a44fc62ac97`) | n/a |

Notes on how it got here, because the branch matters:

- **`ProductCodes` was empty** on the source AMI and verified empty again on
  the target after the copy. A marketplace product code is the one failure no
  retry fixes - it rides the snapshot lineage through `copy-image`,
  `copy-snapshot`, `register-image` and volume round-trips alike, and only a
  block-level `dd` onto a blank volume severs it. It killed the CTI v7 apply
  on 2026-07-05 *after* that leaf had already merged.
- **No transfer CMK.** The source snapshot was unencrypted, so the AMI and
  snapshot were shared directly with `395516496764` and re-encrypted onto the
  LZA EBS key in the destination's single `copy-image`. Re-encrypting to a
  transfer CMK is only needed when the source is on an AWS-managed key
  (`aws/ebs`), which cannot be shared cross-account. Applying that step
  unconditionally costs a full-size, billed, non-incremental snapshot copy per
  server for nothing.
- **Root-only, confirmed not assumed.** The image has one BDM, and the source
  instance had exactly one attachment. Nothing was excluded, so
  `data_volume_snapshot_id` stays empty.

If the source ever pushes a refreshed image, follow the "Refresh procedure"
section in `scriptcase-migration-guide.md` - flow is identical, swap the IDs.

## What this owns

- One EC2 instance from the migrated AMI (private only, no public IP).
- Instance security group allowing SFTP only from the perimeter ingress
  VPC CIDR (default `10.0.0.0/20`).
- Optional admin-SSH ingress rule from the EICE endpoint SG.
- Dedicated IAM role + instance profile (`sftp-server-f9-instance-role`)
  with SSM Session Manager, CloudWatch Agent, and a tightly-scoped
  read/write policy on the `f9-recordings` bucket. Defined in `iam.tf`.

## What this does NOT own

- The shared-prod VPC and subnets (LZA owns them).
- The NLB or any internet-facing piece (sibling leaf).
- The `f9-recordings` S3 bucket itself (sibling leaf).
- Route53 DNS (separate concern).
- The AMI / snapshot copy (already done out-of-band, see provenance above).

## Verifying the instance after apply

CI applies this on merge to `main`. Once it's up, get into the box via SSM
Session Manager. The instance role carries
`AmazonSSMManagedInstanceCore`, and the `user_data` in `main.tf` installs and
enables `amazon-ssm-agent` on first boot (needed because the migrated SFTP
AMIs are Debian, which does not ship the agent by default). Within ~2 minutes
of boot the agent registers and Session Manager is available.

```bash
INSTANCE_ID=<from the apply output / describe-instances>

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
crash), the instance SG also accepts inbound TCP/22 from the shared-prod
EC2 Instance Connect Endpoint SG (`sg-0a990a87e6abca926`), wired up via
`eice_security_group_id` in `terraform.tfvars`. To use it:

```bash
aws ec2-instance-connect ssh \
  --region us-east-2 \
  --instance-id $INSTANCE_ID \
  --connection-type eice \
  --os-user admin
```

Adjust `--os-user` to whatever the migrated image actually uses (`admin` on
Debian, `ec2-user` on Amazon Linux). Useful when troubleshooting the SSM
agent itself - you can `journalctl -u amazon-ssm-agent -n 200` and check
connectivity to `ssm.us-east-2.amazonaws.com` from inside the box.

## Hand-off to the NLB leaf

```bash
# Already pinned to 10.12.1.52 here and pre-filled in the NLB leaf's tfvars,
# so no hand-off edit is needed unless the pin changes.
terraform output -raw private_ip
```

## Common gotchas

- Same as the original `sftp-server` leaf - see that README for the AMI
  not-found, snapshot region, and AZ-pin issues. The cause/fix are
  identical when they hit.
- `disable_api_termination = true` is set, so any future destroy needs the
  provider to call `ModifyInstanceAttribute` first. That action is in the
  TerraformExecution allow-policy, so destroys work, but it doubles the API
  surface a replacement needs.
- `monitoring = false` on purpose. `ec2:MonitorInstances` is missing from the
  TerraformExecution allow-policy, so detailed monitoring cannot be enabled
  from CI on any leaf in this repo until that gap is closed.
