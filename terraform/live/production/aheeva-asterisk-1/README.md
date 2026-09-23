# Aheeva Asterisk 1 (Production / shared-prod) — private

Lift-and-shift of "Aheeva Asterisk 1" from the source tenant
(`254422596287` / `us-east-1`, `i-0783051c356bb7753`, `10.0.100.148`) into
`shared-prod` / `us-east-2`. The Asterisk voice box for the CTI v7 / IVR
cluster — it terminates SIP/RTP with the carriers.

**Private, no load balancer, no EIP.** Per the client: no agents connect, the
SIP is used as an IVR, and everything is reached over the existing Site-to-Site
VPNs. So unlike the source (public, with carrier public IPs in its SG), this box
sits in the private app subnet and the carriers reach it over the VPNs, sourced
from the on-prem ranges routed in `network-config.yaml` (`tgw-rt-spoke`).

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-0783051c356bb7753`, `m5.2xlarge` |
| Root volume | `vol-054d70fa0fca5b9b6`, 100 GiB gp2, **unencrypted** |
| Source AMI | `ami-011939b19c6bd1492` (shared with the two Aheeva DB boxes) |
| Source SG | `sg-0ded5b13e3a7d0320` (`AheevaV7`) |
| Ports served | SIP 5080 (intra-cluster), RTP 10000-20000/udp, 5901/4331/4343/5002-5004 tcp (voice), 3306 (MySQL), 22 + 8443 (admin) |

The source SG referenced the carriers' **public** IPs (`64.89.2.105` Kennedy,
`23.249.138.106` Liberty, `181.207.82.178` Zima, etc.). In the destination those
same carriers arrive over the VPN from their on-prem ranges, so the SG here is
scoped to `var.voice_source_cidrs` (defaulted to the VPN routes) instead. The
box-to-box rules (self-SG-referenced in the source) are scoped to
`var.intra_cluster_cidrs` (the app subnet holding the cluster).

## Prerequisite — AMI copy (one-time, AWS CLI)

Source root volume is **unencrypted**, so no CMK share — the copy just
re-encrypts with the LZA EBS key.

```bash
# 1. Source tenant (254422596287 / us-east-1): fresh image + share to Production
aws ec2 create-image --region us-east-1 --instance-id i-0783051c356bb7753 \
  --name "aheeva-asterisk-1-migration-$(date +%Y%m%d)" --no-reboot
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
  --name "aheeva-asterisk-1-from-source"
```

Put the resulting us-east-2 AMI ID in `terraform.tfvars` as `ami_id`.

## Security-group scopes (all tunable, nothing public)

| Scope | Var | Default | Ports |
|---|---|---|---|
| Cluster peers + CTI v7 | `intra_cluster_cidrs` | app subnet `10.12.1.0/24` | SIP 5080 tcp+udp |
| Voice carriers (over VPN) | `voice_source_cidrs` | the VPN on-prem ranges | RTP 10000-20000/udp; 5901/4331/4343 tcp; 5002-5004 tcp |
| DB consumers | `db_client_cidrs` | app subnet | MySQL 3306 |
| Admins | `admin_cidrs` | app subnet (bastion/EICE) | SSH 22, GUI 8443 |

At the **voice cutover**, prune `voice_source_cidrs` to the carriers actually on
the VPN. Nothing here is open to the internet.

## Apply

Applied by CI on merge. Expect a create (new instance + SG + rules), no destroy.

## See also

- `terraform/live/production/aheeva-db-1/`, `aheeva-db-2/` — the sibling cluster boxes
- `terraform/live/production/cti-v7/` — the IVR box (going private in a separate change)
- `aws-accelerator-config/network-config.yaml` — the VPN routes (`tgw-rt-spoke`)
- `docs/07-Operations/cti-v7-migration-sequencing-plan.md` — the cluster plan
