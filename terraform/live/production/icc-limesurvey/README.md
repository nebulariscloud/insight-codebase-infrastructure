# ICC LimeSurvey (Production / shared-prod)

Lift-and-shift of "ICC_limesurvey" from the source tenant
(`254422596287` / `us-east-1`, `i-0c0ac0e3ee3edee20`, `172.30.0.10`) into
`shared-prod` / `us-east-2`. Private box on Apache :80, fronted by the
dedicated ALB in [`terraform/live/perimeter/limesurvey-alb/`](../../perimeter/limesurvey-alb/).

**All-in-one:** LimeSurvey (PHP) and its MySQL both run on this single box, so
the whole 8 GiB root disk carries the app and its database — no separate DB
dependency.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-0c0ac0e3ee3edee20`, `t2.medium` (ancient; migrated to `t3.small`) |
| Root volume | `vol-07956b3dcf8de2273`, 8 GiB gp2, **unencrypted** |
| Source AMI | `ami-0b33d91d`, **no marketplace product code** (`ProductCodes` empty) |
| Boot mode | null (copy-image sets it automatically) |
| Source SG | `sg-d858fea7` (`webserver`) — served :80 open + :443 to a partner allowlist |
| Ports served | 80, 443 (Apache) |

The source `:443` was locked to a ~30-entry partner allowlist; that allowlist
moves to the **ALB** (`allowed_source_cidrs` in the sibling leaf), not this
instance SG. The instance SG here only accepts :80/:443 from the perimeter
ingress CIDR (the ALB is the sole ingress). The source `:80 -> 0.0.0.0/0` and
the bogus `0.0.0.0/32` SG entries were NOT carried forward.

## Prerequisite — AMI copy (one-time, AWS CLI)

Source root is **unencrypted** and the AMI has **no product code**, so this is
the simple path — a plain cross-account copy-image that re-encrypts with the
LZA EBS key (no CMK share, no dd-sever).

```bash
# 1. Source tenant (254422596287 / us-east-1): fresh image + share to Production
aws ec2 create-image --region us-east-1 --instance-id i-0c0ac0e3ee3edee20 \
  --name "icc-limesurvey-migration-$(date +%Y%m%d)" --no-reboot
# note the returned ami-... (SRC_AMI) and its snapshot (SRC_SNAP)
aws ec2 modify-image-attribute --region us-east-1 --image-id <SRC_AMI> \
  --launch-permission "Add=[{UserId=395516496764}]"
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id <SRC_SNAP> \
  --attribute createVolumePermission --operation-type add --user-ids 395516496764

# 2. Production / us-east-2: copy + re-encrypt with the LZA EBS key
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id <SRC_AMI> --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "icc-limesurvey-from-source"
```

Put the resulting us-east-2 AMI ID in `terraform.tfvars` as `ami_id`.

## Exposure

Private only; reached through the perimeter ALB. Interim state: the ALB serves
**HTTP on its AWS DNS name** (no domain/cert yet) — see the sibling leaf. When
the domain is ready, the ALB gets an ACM cert and HTTPS without touching this
leaf.

## See also

- `terraform/live/perimeter/limesurvey-alb/` — the ALB that fronts this box
- `terraform/live/production/osticket/` — the leaf pattern this mirrors
