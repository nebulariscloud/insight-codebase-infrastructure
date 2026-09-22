# SFTP VOFeeling (Production / shared-prod)

Lift-and-shift of "SFTP VOFeeling" from the source tenant
(`254422596287` / `us-east-1`, `i-0729b47a59c8b756d`) into `shared-prod` /
`us-east-2`. Private EC2 serving SFTP (TCP/22), fronted by the perimeter
ingress NLB in the sibling leaf
[`terraform/live/perimeter/sftp-voice-feeling-nlb/`](../../perimeter/sftp-voice-feeling-nlb/).

Same private-only-behind-ingress-NLB shape as
[`terraform/live/production/sftp-server/`](../sftp-server/), minus the amex
recordings S3 grant (this box doesn't use it).

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-0729b47a59c8b756d`, `t3.micro` |
| Root volume | `vol-064ffe26ef00744be`, 80 GiB gp3, **unencrypted** |
| Source AMI | `ami-0eb9130547efef27b` (snapshot `snap-026529127bece489a`) |
| Source SG | `sg-0f5fd10855b6c0664` (`F9_SFTP_SG`) — inbound TCP/22 from partner IPs |
| Ports served | 22 (SFTP/SSH) |

The source SG allowed TCP/22 from a set of partner IPs (Five9, VICIDIAL,
PEI-BG, CLARA VOFEELING, ZIMA) plus one legacy `0-65535` rule from
`67.219.151.138/32` (VICIDIAL AST1). That partner allowlist is reproduced on
the **NLB** security group in the sibling leaf as `allowed_source_cidrs`; the
instance SG here only accepts TCP/22 from the perimeter ingress CIDR. The wide
`0-65535` rule was NOT carried forward — the NLB forwards only TCP/22. If
VICIDIAL AST1 genuinely needs more than SFTP, add the extra port(s)
explicitly rather than reopening the full range.

## Prerequisite — AMI copy (one-time, AWS CLI)

Source root volume is **unencrypted**, so no customer-CMK share is needed —
the cross-account copy just re-encrypts with the LZA EBS key.

```bash
# 1. Source tenant (254422596287 / us-east-1): share AMI + snapshot to Production
aws ec2 modify-image-attribute --region us-east-1 --image-id ami-0eb9130547efef27b \
  --launch-permission "Add=[{UserId=395516496764}]"
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id snap-026529127bece489a \
  --attribute createVolumePermission --operation-type add --user-ids 395516496764

# 2. Production / us-east-2: copy + re-encrypt with the LZA EBS key
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id ami-0eb9130547efef27b --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "sftp-voice-feeling-from-source"
```

The resulting us-east-2 AMI (`ami-08530cb077a854142`) is set as `ami_id` in
`terraform.tfvars`.

## Apply

Applied by CI on merge (see the repo Terraform PR workflow). The order is:

1. This leaf first — it prints `private_ip`.
2. Paste that IP into
   `../../perimeter/sftp-voice-feeling-nlb/terraform.tfvars` as
   `sftp_server_private_ip` (it's pre-pinned to `10.12.1.62`).
3. The NLB leaf second.

## Notes

- SSM-only access by default (`key_name` empty). Admin SSH via EICE is
  available by setting `eice_security_group_id`.
- If the migrated sshd is pinned to the old private IP via `ListenAddress`
  in `/etc/ssh/sshd_config`, reset it to `0.0.0.0` and restart sshd — the
  NLB health check and client traffic arrive on the new private IP.

## See also

- `terraform/live/production/sftp-server/` — the reference SFTP leaf (with amex grant)
- `terraform/live/perimeter/sftp-voice-feeling-nlb/` — the NLB that exposes this box
- `snapshot-ami-migration-guide.md` — the copy procedure
