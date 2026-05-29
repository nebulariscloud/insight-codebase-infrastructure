# PCI Onboarding Guide

End-to-end guide for spinning up the PCI account, network, and load balancer
in this LZA-managed organization. Everything in the config repo for PCI is
already authored - this guide is the **rollout sequence** to take it from
"committed but commented out" to "running and ready for cardholder workloads".

---

## Why a Dedicated PCI Account & VPC

PCI scope follows cardholder data flow. Anything that processes, stores, or
transmits cardholder data is in scope, plus everything connected to those
systems unless properly segmented.

The architecture choice here is **scope minimization**:

- Dedicated `PCI` AWS account inside the `Workloads/PCI` OU
- Dedicated VPC inside that account (NOT a subnet share from the Network account)
- Dedicated TGW route table (`tgw-rt-pci`) so PCI can only reach the egress VPC.
  Dev/Test/Prod and PCI cannot route to each other through the TGW.
- Dedicated public ALB inside the PCI account (NOT the shared Perimeter ingress
  ALB). Putting the LB in Perimeter would drag every other Perimeter-hosted
  workload into PCI scope.
- Dedicated WAF on the PCI ALB, tuned tighter than the standard ingress WAF
  (lower rate limit, SQLi rules added, HTTPS-only).
- Conformance pack ("Operational Best Practices for PCI DSS 4.0") deployed only
  to the PCI account.
- Dedicated CIDR space (`10.16.0.0/14`) so the network boundary is visible to
  an auditor at a glance.

Trade-off: you run an extra ALB ($16/mo + LCUs) and an extra WAF (~$5/mo + per
managed rule + per request) compared to the shared LB pattern. Cheap relative
to expanding PCI scope across Perimeter.

---

## What's Already in the Repo

All PCI assets are committed but mostly commented out so the existing pipeline
runs aren't disturbed. Locations:

| File | What's there |
|---|---|
| `thenew-aws-accelerator-config/organization-config.yaml` | `Workloads/PCI` OU active, all SCPs/RCP/declarative-policy attachments cover it |
| `thenew-aws-accelerator-config/global-config.yaml` | All 12 Control Tower controls cover `Workloads/PCI` |
| `thenew-aws-accelerator-config/accounts-config.yaml` | `PCI` account block (currently uncommented, gated by AWS Org account quota) |
| `thenew-aws-accelerator-config/replacements-config.yaml` | `HomeRegionPciWorkloadsCidr` and PCI subnet mask vars active |
| `thenew-aws-accelerator-config/network-config.yaml` | `tgw-rt-pci`, PCI IPAM pool, PCI VPC - all commented out |
| `thenew-aws-accelerator-config/custom-stacks/pci-alb.yaml` | Template ready, unreferenced until customizations block is uncommented |
| `thenew-aws-accelerator-config/custom-stacks/pci-dss-conformance-pack.yaml` | Template ready, unreferenced until customizations block is uncommented |
| `thenew-aws-accelerator-config/customizations-config.yaml` | `PciAlb` and `PciDssConformancePack` blocks - both commented out |

---

## Architecture

```
Internet
  │
  ▼
PCI Account / us-east-2
  ├─ PCI VPC  (10.16.0.0/20, dedicated CIDR space)
  │   ├─ pci-public-a / pci-public-b   (ALB only - IGW route)
  │   │   └─ PCI ALB (HTTPS-only, WAF, deletion protection, access logs)
  │   ├─ pci-app-a / pci-app-b         (cardholder workloads - TGW + S3/DDB endpoints)
  │   ├─ pci-data-a / pci-data-b       (DBs - NO internet route, S3/DDB endpoints only)
  │   └─ pci-tgw-a / pci-tgw-b         (TGW attachment subnets)
  │
  └─ TGW attachment associated to tgw-rt-pci (NOT tgw-rt-spoke)
      └─ Only route: 0.0.0.0/0 → egress VPC in Perimeter (NAT)
```

The `tgw-rt-pci` route table has exactly one route: 0/0 to the egress VPC. The
spoke route table (`tgw-rt-spoke`) does NOT have a route to PCI's CIDR. That
means:

- PCI can egress to the internet via NAT in Perimeter (firewall in front)
- PCI cannot reach Dev, Test, Prod, SharedServices, or Endpoints VPCs over TGW
- None of those can reach PCI either

---

## Rollout Sequence

The order matters - each step depends on the previous.

### Step 0 - Prerequisite: AWS Org account quota

Currently your AWS Organizations is at the account quota (12 active). PCI
account creation will keep failing with `ConstraintViolationException` until a
limit increase comes through. See `account-decommission-guide.md` (or open a
support case directly: AWS Organizations → Number of accounts → 25).

### Step 1 - Create the PCI account

The `accounts-config.yaml` block for PCI is already uncommented. The next time
the LZA pipeline runs after the quota increase is approved, the account will be
vended into `Workloads/PCI` automatically.

```bash
# Wait for the pipeline to finish, then verify
aws organizations list-accounts \
  --query 'Accounts[?Name==`PCI`].{Id:Id,Email:Email,Status:Status}' \
  --output table
```

You should see one account with status `ACTIVE`. Note the account ID -
you'll need it for several later steps.

### Step 2 - Uncomment and apply the PCI network

In `thenew-aws-accelerator-config/network-config.yaml`, uncomment in this order:

1. `tgw-rt-pci` route table (in the `transitGateways[0].routeTables` list)
2. `ipam-pci-pool` (in the IPAM `pools` list)
3. The PCI VPC block (the long commented section that starts with
   `# - name: "{{ AcceleratorPrefix }}-{{ HomeRegion }}-pci"`)

Push and run the pipeline. LZA will:

- Create the `tgw-rt-pci` route table on the existing TGW
- Provision the PCI IPAM pool from the global pool, share it to the PCI account
- Create the PCI VPC + 8 subnets + 7 route tables in the PCI account
- Attach the VPC to the TGW with association to `tgw-rt-pci` only
- Propagate routes to `tgw-rt-firewall` so egress traffic returns

After it finishes, capture the IDs you'll need:

```bash
# In the PCI account, us-east-2
aws ec2 describe-vpcs --region us-east-2 \
  --filters "Name=tag:Name,Values=AWSAccelerator-us-east-2-pci" \
  --query 'Vpcs[0].VpcId' --output text

aws ec2 describe-subnets --region us-east-2 \
  --filters "Name=vpc-id,Values=<vpc-id-from-above>" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,AZ:AvailabilityZone}' \
  --output table
```

You'll get back the VPC ID and the 8 subnets. Save the IDs of `pci-public-a`
and `pci-public-b` for Step 4.

### Step 3 - Provision the ACM cert in the PCI account

The PCI ALB requires a real ACM cert. See `acm-certificate-and-https-guide.md`
for the full workflow. Summary:

```bash
# In the PCI account, us-east-2
aws acm request-certificate --region us-east-2 \
  --domain-name <pci-app-hostname> \
  --validation-method DNS

# Add the validation CNAME at your DNS provider, then wait
aws acm wait certificate-validated --region us-east-2 \
  --certificate-arn <cert-arn>
```

Save the cert ARN.

### Step 4 - Set up the elb-access-logs bucket (recommended for PCI)

PCI DSS 10.x requires logging of network access. The PCI ALB template references
the LZA-pattern bucket name `aws-accelerator-elb-access-logs-<pci-account-id>-<region>`.
LZA creates this bucket as part of the `logging` stage. Verify it exists in the
PCI account before proceeding:

```bash
aws s3 ls --region us-east-2 | grep aws-accelerator-elb-access-logs
```

If it doesn't exist yet, the next pipeline run after the account is created
will provision it. Wait for that.

### Step 5 - Uncomment and apply the PCI ALB

In `thenew-aws-accelerator-config/customizations-config.yaml`, find the `PciAlb`
block (commented). Uncomment it and fill in:

- `VpcId`: from Step 2
- `PublicSubnetA`, `PublicSubnetB`: from Step 2
- `CertificateArn`: from Step 3
- `AccessLogsBucketName`: from Step 4
- `TargetPort`, `TargetProtocol`, `HealthCheckPath`, `HealthCheckMatcher`:
  match what your PCI app actually serves

Push and run the pipeline. LZA will deploy `pci-alb.yaml` into the PCI account.

After it finishes, get the ALB DNS name and the WAF ARN:

```bash
aws cloudformation describe-stacks --region us-east-2 \
  --query 'Stacks[?contains(StackName,`PciAlb`)].Outputs' \
  --output table
```

### Step 6 - DNS

CNAME (or Route53 alias) your PCI app hostname to the ALB DNS name from Step 5.
See `acm-certificate-and-https-guide.md` Step 6 for the exact commands.

### Step 7 - Conformance pack

The PCI DSS 4.0 conformance pack is the last piece. AWS Config requires the
template body to be in S3, and the bucket name must start with
`awsconfigconforms`.

```bash
# In the PCI account, us-east-2
aws s3 mb s3://awsconfigconforms-pci-dss-templates --region us-east-2

aws s3api put-public-access-block \
  --bucket awsconfigconforms-pci-dss-templates \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption \
  --bucket awsconfigconforms-pci-dss-templates \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-versioning \
  --bucket awsconfigconforms-pci-dss-templates \
  --versioning-configuration Status=Enabled

curl -L -o pci-dss-4.0.yaml \
  https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-PCI-DSS-4.0-Including-global-resource-types.yaml

aws s3 cp pci-dss-4.0.yaml s3://awsconfigconforms-pci-dss-templates/pci-dss-4.0.yaml
```

Then in `customizations-config.yaml`, uncomment the `PciDssConformancePack`
block. Push and run the pipeline. The conformance pack lands in the PCI account
and Config starts evaluating it on the next recording cycle.

---

## Things This Guide Skips

- **AWS Network Firewall in front of PCI.** This LZA setup deliberately removed
  Network Firewall to save ~$570/mo. PCI workloads typically benefit from a
  stateful firewall before egress. If you decide you want it, that's a separate
  project: re-introduce the Inspection VPC and route PCI's egress through it
  before reaching the egress VPC's NAT. See the upstream LZA reference for the
  inspection pattern.
- **VPC interface endpoints in the PCI VPC.** The PCI VPC is set to
  `useCentralEndpoints: true` which routes interface-endpoint DNS to the central
  Endpoints VPC. That works because the central endpoints are reachable via TGW
  (route in `tgw-rt-pci`'s 0/0 path that goes through Perimeter back into TGW).
  If your auditor wants endpoints local to the PCI VPC, switch
  `useCentralEndpoints` to false and define `interfaceEndpoints` directly on
  the PCI VPC. Costs more.
- **Cross-account log aggregation.** PCI access logs go to a bucket in the PCI
  account; LZA's `centralLogBucket` in LogArchive aggregates org-wide logs via
  replication. Confirm with whoever's running your QSA that the LogArchive
  bucket meets PCI 10.5 (write-once equivalents).
- **Application-side TLS configuration, key management, and the actual PCI
  controls 4-12.** Out of scope for this network-and-LB guide.

---

## Validation Checklist

After all steps complete:

- [ ] `aws organizations list-accounts` shows PCI as ACTIVE
- [ ] `aws ec2 describe-vpcs` in PCI account returns the PCI VPC
- [ ] All 8 subnets visible in `aws ec2 describe-subnets`
- [ ] TGW attachment associated with `tgw-rt-pci` only
- [ ] From the PCI app subnet, `curl https://<pci-alb-dns>` returns the app
- [ ] From a Dev/Test/Prod workload, `curl <pci-internal-ip>` is unreachable
- [ ] WAF metrics in CloudWatch show traffic samples
- [ ] AWS Config conformance pack shows COMPLIANT/NON_COMPLIANT evaluations
  (compliance state may take an hour after creation)
- [ ] CloudTrail data events for any PCI-account S3 bucket are flowing to
  LogArchive
- [ ] VPC flow logs from the PCI VPC are flowing to CloudWatch Logs

---

## Rollback

If you need to back any of this out:

```bash
# In the PCI account
aws cloudformation delete-stack --region us-east-2 --stack-name <pci-alb-stack>
aws cloudformation delete-stack --region us-east-2 --stack-name <pci-conformance-pack-stack>
```

Then re-comment the relevant blocks in the config repo and run the pipeline.
LZA-managed resources (VPC, IPAM, TGW route table) are reverted by re-commenting
those entries; the next pipeline run will detect the diff and remove them.

The PCI **account** itself cannot be removed by re-commenting. To close the
account, follow `account-decommission-guide.md`.
