# Aheeva DB 1 (Production / shared-prod) — private

Lift-and-shift of "Aheeva DB 1" from the source tenant
(`254422596287` / `us-east-1`, `i-04c049934876c5c94`, `10.0.100.221`) into
`shared-prod` / `us-east-2`. Part of the CTI v7 / IVR cluster.

**Private, no load balancer, no EIP.** Reached over shared-prod / TGW by the
cluster peers and over the Site-to-Site VPNs by any on-prem consumers.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-04c049934876c5c94`, `m5.2xlarge` |
| Root volume | `vol-0d43d944f04f719e4`, 200 GiB gp2, **unencrypted** |
| Source AMI | `ami-011939b19c6bd1492` (shared with the Asterisk + DB 2 boxes) |
| Source SG | `sg-0ded5b13e3a7d0320` (`AheevaV7`) |
| Primary port | MySQL 3306 (plus the shared cluster SG ports) |

The three Aheeva boxes shared one SG; this leaf reproduces the same scoped
shape (see the `aheeva-asterisk-1` README for the full scope rationale). If this
box serves no voice, set `voice_source_cidrs = []` in tfvars.

## Prerequisite — AMI copy (one-time, AWS CLI)

Source root volume is **unencrypted** — the copy re-encrypts with the LZA EBS key.

```bash
aws ec2 create-image --region us-east-1 --instance-id i-04c049934876c5c94 \
  --name "aheeva-db-1-migration-$(date +%Y%m%d)" --no-reboot
aws ec2 modify-image-attribute --region us-east-1 --image-id <SRC_AMI> \
  --launch-permission "Add=[{UserId=395516496764}]"
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id <SRC_SNAP> \
  --attribute createVolumePermission --operation-type add --user-ids 395516496764

TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id <SRC_AMI> --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "aheeva-db-1-from-source"
```

Put the resulting us-east-2 AMI ID in `terraform.tfvars` as `ami_id`.

## Apply

Applied by CI on merge. Expect a create, no destroy.

## See also

- `terraform/live/production/aheeva-asterisk-1/`, `aheeva-db-2/` — sibling cluster boxes
- `docs/07-Operations/cti-v7-migration-sequencing-plan.md` — the cluster plan
