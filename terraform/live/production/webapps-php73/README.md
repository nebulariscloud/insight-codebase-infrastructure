# Webapps PHP 7.3 (Production / shared-prod) — Wave 1

Lift-and-shift of "webapps php7.3" from the source tenant
(`254422596287` / `us-east-1`, `i-02a7982851dd09a0b`, `172.30.2.118`) into
`shared-prod` / `us-east-2`. Private EC2, serves HTTP 80 + HTTPS 443, fronted by
the perimeter ingress ALB. Paired with the webapps server.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-02a7982851dd09a0b`, `t3a.micro` |
| Root volume | `vol-0980c810405e6c44b`, 40 GiB gp2, **encrypted (customer CMK `6e7aced8-e4e6-4060-8b71-b00099d5412f`)** |
| Source AMI | `ami-06aa72d877cc1b233` ("Restoration Image 7.3"), no marketplace product code |
| Ports served | 80, 443 |
| Source SGs | `sg-93433fe3`, `sg-d85925a8` (shared with webapps server) |

## Prerequisite — AMI copy WITH CMK sharing (one-time, AWS CLI)

Unlike the webapps server (unencrypted), this box's root volume is encrypted
with a **customer-managed CMK**. That CMK must be shared to Production before
the cross-account copy can read the snapshot. Follow
`snapshot-ami-migration-guide.md` Part 2:

```bash
# 1. Source tenant: add Production to the CMK key policy (kms:Decrypt,
#    kms:CreateGrant, kms:DescribeKey, kms:ReEncrypt*, kms:GenerateDataKey*)
#    for arn:aws:iam::395516496764:root — key 6e7aced8-e4e6-4060-8b71-b00099d5412f

# 2. Source tenant: fresh AMI + share AMI and its snapshot to Production
aws ec2 create-image --region us-east-1 --instance-id i-02a7982851dd09a0b \
  --name "webapps-php73-migration-$(date +%Y%m%d)" --no-reboot
aws ec2 modify-image-attribute --region us-east-1 --image-id <src-ami> \
  --launch-permission "Add=[{UserId=395516496764}]"
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id <src-snap> \
  --attribute createVolumePermission --operation-type add --user-ids 395516496764

# 3. Production / us-east-2: copy + re-encrypt with the LZA EBS key
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id <src-ami> --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "webapps-php73-from-source"
```

Put the resulting AMI ID in `terraform.tfvars` as `ami_id`.

## Apply

```bash
cd terraform/live/production/webapps-php73
terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan
terraform output -raw private_ip   # register on the perimeter ingress ALB
```

## Notes

- During Wave 1 this box still points at the SOURCE RDS over egress; DB cutover
  is Wave 2.
- Same private-only-behind-ingress-ALB shape as `terraform/live/production/webapps/`.

## See also

- `terraform/live/production/webapps/` — the paired webapp (unencrypted source)
- `snapshot-ami-migration-guide.md` — the CMK-share + copy procedure
