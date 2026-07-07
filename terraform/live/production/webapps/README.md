# Webapps Server (Production / shared-prod) — Wave 1

Lift-and-shift of the "webapps server" from the source tenant
(`254422596287` / `us-east-1`, `i-0fb5b86437a72deb5`, `172.30.0.34`) into
`shared-prod` / `us-east-2`. Private EC2, serves HTTP 80 + HTTPS 443, fronted by
the perimeter ingress ALB.

## What this owns

- One EC2 instance from the migrated AMI (private, no public IP).
- Instance security group allowing 80 + 443 from the perimeter ingress VPC CIDR
  only (the ALB is the sole ingress).
- Optional EICE admin SSH.

## What this does NOT own

- The shared-prod VPC / subnets (LZA-managed).
- The perimeter ingress ALB target group + listener rule (sibling perimeter
  leaf — register this leaf's `private_ip` output there).
- The AMI copy (one-time, before applying).
- DB connectivity: during Wave 1 this box still points at the SOURCE RDS
  (`iccmaindb...us-east-1...`) over egress. The DB cutover is Wave 2.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-0fb5b86437a72deb5`, `t3.small` |
| Root volume | `vol-0bae7749d075f3dcd`, 45 GiB gp2, **unencrypted** |
| Source AMI | `ami-0f2d2a74` ("webappsServer"), no marketplace product code |
| Ports served | 80, 443 (behind an ELB in source) |
| Source SGs | `sg-93433fe3` (SSHWebserverBackend), `sg-d85925a8` (ELBOnlyHTTPTraffic) |

## Prerequisite — AMI copy (one-time, AWS CLI)

Source AMI has no marketplace code, so a plain cross-account share works. The
source root volume is unencrypted, so no CMK sharing is needed for the share;
encryption is applied on the destination copy:

```bash
# Source tenant: fresh AMI + share to Production
aws ec2 create-image --region us-east-1 --instance-id i-0fb5b86437a72deb5 \
  --name "webapps-migration-$(date +%Y%m%d)" --no-reboot
aws ec2 modify-image-attribute --region us-east-1 --image-id <src-ami> \
  --launch-permission "Add=[{UserId=395516496764}]"
# also share the backing snapshot (createVolumePermission) — see snapshot-ami-migration-guide.md

# Production / us-east-2: copy + re-encrypt with the LZA EBS key
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id <src-ami> --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "webapps-from-source"
```

Put the resulting AMI ID in `terraform.tfvars` as `ami_id`.

## Apply

```bash
cd terraform/live/production/webapps
terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan
terraform output -raw private_ip   # register on the perimeter ingress ALB
```

## See also

- `terraform/live/production/sftp-server/` — the leaf pattern this mirrors
- `terraform/live/production/webapps-php73/` — the paired PHP 7.3 webapp
- `cti-v7-cluster-migration-plan.md` — the overall cluster plan
