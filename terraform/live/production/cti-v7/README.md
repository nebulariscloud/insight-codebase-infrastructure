# Aheeva CTI v7 (Production / shared-prod) — Option B, direct-EIP SIP endpoint

Lift-and-shift of the Aheeva CTI v7 server from the source tenant
(`254422596287` / `us-east-1`, instance `i-03f52a172a049b1a8`, EIP
`54.152.253.96`) into `shared-prod` / `us-east-2`.

> **This leaf is a design draft.** It will not apply cleanly until the
> Option B guardrail-exception prerequisites (below) are in place. CI will
> `plan` it, but `apply` fails until the public subnet exists and the SCP
> exception is live. Do not merge expecting it to build infra yet.

## Why this leaf is unlike the other production leaves

Every other migrated box in this repo (`sftp-server`, the webapps) is
private-only behind the perimeter load balancers. CTI v7 can't be, because
it is a **SIP endpoint**:

- SIP trunks do **not** register — they're IP-authenticated, peer-to-peer.
- RTP media terminates **directly** on the box (no SBC / media proxy).
- Aheeva's `sip.conf` hardcodes `externip = 54.152.253.96` (the box's own
  public IP), and the **Aheeva license is keyed to that public IP**.

Behind NAT, RTP breaks (one-way audio) and the license fails to validate.
So CTI v7 needs a **directly-attached public IP** (an EIP on its own ENI in
a public subnet) — the "Option B" shape from
[`docs/07-Operations/cti-v7-migration-options.md`](../../../../docs/07-Operations/cti-v7-migration-options.md).

That shape is normally forbidden in a workload spoke. This leaf depends on a
narrow, tag-scoped exception to the LZA guardrails.

## What this leaf owns

- One EC2 instance from the migrated AMI, in a **public** shared-prod subnet.
- An **Elastic IP** attached to the instance (via the `ec2-migrated` module's
  `allocate_eip = true`).
- An instance security group allowing:
  - **SIP UDP 5060** from the VoIP gateway (Liberty DC) IPs.
  - **RTP UDP 10000-11000** from the SIP peers + confirmed extra RTP sources.
  - **Admin TCP 8443** from the perimeter ingress ALB CIDR only.
- The `Migrated = CTIv7` tag that the SCP exception keys on.

## What this leaf does NOT own

- The public subnet, IGW, public route table (LZA `network-config.yaml`).
- The VPC Block Public Access exclusion (LZA declarative policy).
- The SCP exception (LZA `organization-config.yaml` +
  `service-control-policies/`).
- The AMI copy + re-encrypt (one-time, source tenant → us-east-2).
- The perimeter ingress ALB target group + listener rule for the 8443 GUI
  (separate perimeter leaf).
- The Aheeva license reissue (vendor coordination).

## Prerequisites — must all exist before `apply`

These are separate PRs / actions. This leaf's `apply` fails without them.

### 1. LZA guardrail exception (drafted — see the dedicated doc)

The full design, apply order, verification, and rollback are in
[`docs/07-Operations/cti-v7-lza-exception.md`](../../../../docs/07-Operations/cti-v7-lza-exception.md).
Summary of the three parts:

1. **SCP** (`service-control-policies/lza-core-workloads-guardrails-1.json`) —
   `ec2:AllocateAddress` / `ec2:AssociateAddress` moved out of the blanket
   `GRNETSEC2` deny into tag-scoped statements that only deny when the resource
   is NOT tagged `Migrated == CTIv7`. (SCPs are deny-only, so the fix is
   narrowing the deny, not adding an allow.)
2. **Network** (`network-config.yaml`, shared-prod VPC) — `internetGateway:
   true`, plus a `shared-prod-rt-public-a` route table (IGW default route) and a
   `shared-prod-public-a` /27 subnet shared to Production. Modeled on the PCI
   VPC's public-subnet pattern.
3. **VPC Block Public Access exclusion** — a runtime `create-vpc-block-public-
   access-exclusion` call in the Network account. NOT a config edit; the
   declarative policy already allows exclusions.

### 2. AMI copy + re-encrypt (one-time, AWS CLI)

The source root volume is **unencrypted** 200 GiB gp2. Copy the source AMI
into `us-east-2` re-encrypting with the LZA EBS key:

```bash
# In the source tenant: share the AMI to 395516496764 (see snapshot-ami-migration-guide.md)
# Then in shared-prod / us-east-2:
TARGET_KEY_ARN=$(aws kms describe-key --region us-east-2 \
  --key-id alias/accelerator/ebs/default-encryption/key \
  --query 'KeyMetadata.Arn' --output text)

aws ec2 copy-image --region us-east-2 --source-region us-east-1 \
  --source-image-id <shared-src-ami> \
  --encrypted --kms-key-id "$TARGET_KEY_ARN" \
  --name "cti-v7-from-source"
```

Put the resulting AMI ID in `terraform.tfvars` as `ami_id`.

### 3. Aheeva license re-allowlist (vendor)

CTI v7 phones home to the Aheeva License Server on **TCP 5053 + 50555**. The
vendor allowlists the box's public IP. Once this leaf allocates the new EIP
(visible in the `public_ip` output), give that IP to the Aheeva vendor
(Franco Delménico) to re-allowlist **before** cutover.

## Cutover notes (Aheeva config edits, out of band)

Inside the instance after it boots, before going live:

- Set `externip = <new EIP>` in `sip.conf` (replacing `54.152.253.96`).
- `localnet` stays as the internal range for the new subnet.
- `nat = force_rport,comedia` unchanged.
- RTP range `rtpstart=10000` / `rtpend=11000` unchanged.

## Confirmed source facts (for reference)

| Fact | Value |
|---|---|
| Source instance | `i-03f52a172a049b1a8`, `m5.2xlarge` |
| Source EIP | `54.152.253.96` |
| Root volume | `/dev/sda1`, 200 GiB gp2, **unencrypted** |
| SIP | UDP 5060, plain (no TLS) |
| RTP | UDP 10000-11000, plain (no SRTP) |
| SIP peers | `199.116.62.102`, `23.249.138.106` (Liberty DC) |
| RTP extras | `64.89.2.105`, `66.231.161.164`, `1.1.1.1` (intentional) |
| License | IP-keyed, phone-home TCP 5053 + 50555 |
| Admin | 8443 web GUI (behind perimeter ALB) |

## First-time apply (once prerequisites are met)

```bash
cd terraform/live/production/cti-v7
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan

# Grab the new EIP to hand to the Aheeva vendor and to set as externip.
terraform output -raw public_ip
```

## See also

- `docs/07-Operations/cti-v7-migration-options.md` — the option analysis (internal)
- `cti-v7-cluster-migration-plan.md` — the overall cluster plan
- `eip-cross-org-migration-guide.md` — the direct-EIP guardrail-exception recipe
- `terraform/live/production/sftp-server/` — the standard (private) migrated-leaf pattern
