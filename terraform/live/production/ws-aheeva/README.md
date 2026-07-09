# WS Aheeva (Production / shared-prod) — Wave 2

Lift-and-shift of the WS Aheeva file-loader from the source tenant
(`254422596287` / `us-east-1`, `i-025bede8c30dbcece`, `172.30.2.200`) into
`shared-prod` / `us-east-2`.

WS Aheeva is the box **clients drop daily files onto over FTPS**; it processes
them and writes into the RDS (`iccmaindb`). It is the disk-mutable, client-
facing member of the cluster, so it migrates in **Wave 2** and cuts over with
the RDS.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-025bede8c30dbcece`, `t3a.medium` |
| Root volume | `vol-0e72a3800ccb08eec`, 80 GiB gp2, **encrypted (aws/ebs — unshareable)** |
| Source AMI | `ami-0f38562b9d4de0dfe`, no marketplace product code |
| File-drop | **FTPS**: control 990 (implicit TLS) + passive 40000-40500 |
| Source SG | `sg-0236c297e78a62ab2` (WebServerAWS): 990, 40000-40500, 8025, 8078, 8081, 3389 (RDP), 22, all-traffic from Aheeva-family IPs |
| DB role | Writes to `iccmaindb`; also a 3306 client of it |

## What this leaf owns

- One EC2 instance from the migrated AMI (private, no public IP).
- Instance SG: FTPS control + passive from the perimeter ingress NLB CIDR, plus
  optional extra Aheeva app/admin ports scoped to admin CIDRs.
- Optional EICE admin SSH.

## What this does NOT own

- The FTPS ingress NLB — sibling leaf `terraform/live/perimeter/ws-aheeva-ftps-nlb/`.
- The RDS (`terraform/live/production/iccmaindb/`).
- The AMI copy (one-time, transfer-CMK dance — below).

## Prerequisite — AMI via transfer-CMK re-encrypt (source is aws/ebs)

The source root volume is encrypted with `aws/ebs` (AWS-managed, unshareable),
so the plain share fails. Same procedure as webapps-php73 (reuse the same
source transfer CMK if it still exists):

```bash
# Source tenant: create AMI (at cutover, after draining the file queue), get its snapshot
WS_AMI=$(aws ec2 create-image --region us-east-1 --instance-id i-025bede8c30dbcece \
  --name "ws-aheeva-migration-$(date +%Y%m%d)" --no-reboot --query ImageId --output text)
WS_SNAP=$(aws ec2 describe-images --region us-east-1 --image-ids $WS_AMI \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)

# Re-encrypt to a shareable customer CMK (XFER_KEY), share to Production
XFER_SNAP=$(aws ec2 copy-snapshot --region us-east-1 --source-region us-east-1 \
  --source-snapshot-id $WS_SNAP --encrypted --kms-key-id $XFER_KEY \
  --query SnapshotId --output text)
aws ec2 modify-snapshot-attribute --region us-east-1 --snapshot-id $XFER_SNAP \
  --attribute createVolumePermission --operation-type add --user-ids 395516496764

# Production / us-east-2: copy cross-region + re-encrypt with the LZA EBS key, register-image
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key --query 'KeyMetadata.Arn' --output text)
WS_DEST_SNAP=$(aws ec2 copy-snapshot --region us-east-2 --source-region us-east-1 \
  --source-snapshot-id $XFER_SNAP --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --query SnapshotId --output text)
# register-image from WS_DEST_SNAP (confirm root device / ENA / boot mode off the source AMI)
```

Put the resulting AMI ID in `terraform.tfvars`.

> **Mutable disk:** WS Aheeva's inbox changes as clients drop files. Take the
> FINAL AMI at the cutover window AFTER pausing client sends and draining the
> queue, so no in-flight file is lost. A baseline AMI can be made earlier to
> pre-stage, but the authoritative one is at cutover.

## Cutover (with the RDS)

1. Tell FTPS clients to pause sends; drain the inbound queue on the source.
2. Take the final AMI (above), deploy this leaf.
3. Point WS Aheeva's DB connection at the promoted `iccmaindb` endpoint
   (config edit inside the box, over SSH/SSM).
4. Apply the FTPS NLB leaf; give clients the NLB endpoint + allowlist the NLB's
   public IPs; they resume sends.
5. Verify a test file lands and processes end-to-end into the new RDS.

## FTPS client coordination

The FTPS clients allowlisted on the source SG (990 + passive) must be told the
new endpoint and (for outbound-from-them) allowlist the NLB's public IPs. Put
their source CIDRs in `ftps_client_cidrs` (enforced at the NLB SG) and confirm
the real active list before cutover.

## See also

- `terraform/live/perimeter/ws-aheeva-ftps-nlb/` — the FTPS ingress NLB
- `terraform/live/production/iccmaindb/` — the RDS this box writes to
- `terraform/live/production/webapps-php73/` — the transfer-CMK AMI pattern
- `cti-v7-cluster-migration-plan.md` — overall plan
