# CTI v7 — LZA guardrail exception (Option B)

The CTI v7 SIP endpoint needs a directly-attached public IP in `shared-prod`
(see `cti-v7-migration-options.md`, Option B). The LZA guardrails forbid that
shape by default. This document is the record of the narrow, tag-scoped
exception that permits it — what changed, why, the apply order, and how to
verify and roll back.

**Scope of the exception, in one sentence:** one `/27` public subnet in the
`shared-prod` VPC, reachable via an IGW, in which a single EC2 instance tagged
`Migrated = CTIv7` may have an Elastic IP. Nothing else in `shared-prod`
changes posture.

## Why the naive approach doesn't work

The first instinct — "add an Allow SCP for `ec2:AllocateAddress`" — is wrong.
**SCPs are deny-only guardrails; an explicit `Deny` always overrides any
`Allow`.** The workload SCP `lza-core-workloads-guardrails-1.json` has an
explicit `Deny` on `ec2:AllocateAddress` / `ec2:AssociateAddress` for every
principal whose ARN is not `AWSAccelerator*`, the management role, or
`cdk-accel*`. TerraformExecution is not on that list. You cannot out-allow a
deny; you have to narrow the deny itself.

## The three moving parts

The exception spans two AWS accounts and three mechanisms. All three must be in
place before the CTI v7 Terraform leaf's `apply` runs.

### Part 1 — SCP: carve the EIP actions out of the blanket deny

**File:** `aws-accelerator-config/service-control-policies/lza-core-workloads-guardrails-1.json`
**Applies to:** the `Workloads/Prod` OU (which contains the Production account),
via `organization-config.yaml`.

`ec2:AllocateAddress` and `ec2:AssociateAddress` were removed from the blanket
`GRNETSEC2` deny and moved into two new tag-scoped statements:

- `GRNETSEC2EIPAllocate` — denies `ec2:AllocateAddress` unless
  `aws:RequestTag/Migrated == CTIv7`. (Allocate is a create action: the tag is
  on the *request*, so `RequestTag` is the correct key. This requires the EIP
  to be tagged **at creation time**, not after — see the verification note.)
- `GRNETSEC2EIPAssociate` — denies `ec2:AssociateAddress` unless
  `aws:ResourceTag/Migrated == CTIv7`. (Associate acts on an existing EIP that
  already carries the tag, so `ResourceTag` is correct.)

Everything else in `GRNETSEC2` (IGW/subnet/route/VPC/TGW create-deletes) is
unchanged and still fully denied for non-LZA principals. Only the two EIP verbs
were narrowed, and only for the one tag value.

Split into two statements deliberately: Allocate and Associate use different
condition keys (`RequestTag` vs `ResourceTag`). A single combined statement
would rely on IAM's null-key evaluation semantics and could silently fail open
or closed on one of the two actions. Two statements are unambiguous.

SCP size after the edit: ~2.5 KB minified, well under the 5 KB AWS limit.

### Part 2 — Network: IGW + public subnet in shared-prod

**File:** `aws-accelerator-config/network-config.yaml`, the
`{{ AcceleratorPrefix }}-{{ HomeRegion }}-shared-prod` VPC (Network account,
subnets shared to Production via RAM).

Three additions, all modeled on the existing PCI VPC (`pci-rt-public-*` +
`pci-public-*`), which is the in-repo precedent for a workload VPC with a
public subnet:

1. `internetGateway: false` → `true`.
2. New route table `shared-prod-rt-public-a`:
   - `{{ GlobalCidr }}` (10.0.0.0/8) → TGW — so internal traffic to WS Aheeva
     and the rest of the estate still goes over the private backbone.
   - `0.0.0.0/0` → `internetGateway` — only non-internal destinations use the
     IGW.
3. New subnet `shared-prod-public-a`, AZ a, `/27`, on that route table, shared
   to the Production account.

The existing app/data/tgw subnets and their route tables are untouched — they
remain `0.0.0.0/0 → TGW` (private). The public subnet is additive.

**Account topology note:** the VPC and subnet live in the **Network** account
and are shared into **Production** via RAM. The EC2 instance and its EIP are
created in **Production** (that's where the CTI v7 leaf assumes
TerraformExecution). The workload SCP applies to Production, which is why the
Part 1 change is what unblocks the EIP.

### Part 3 — VPC Block Public Access exclusion (runtime, NOT a config edit)

**This is the part that is easy to get wrong.** The declarative policy
`declarative-policies/lza-core-vpc-block-public-access.json` is already correct
and needs **no change** — it sets `internet_gateway_block: block_bidirectional`
with `exclusions_allowed: enabled`. That last flag means exclusions are
*permitted*; it does not create one.

The actual exclusion is a **runtime AWS API call** in the Network account
against the shared-prod VPC (or specifically the public subnet). Without it,
the IGW from Part 2 exists but BPA silently drops the traffic:

```bash
# In the Network account, us-east-2, with a principal not denied by the
# infrastructure SCP (BPA exclusion creation is not in the deny list, but
# confirm against lza-infrastructure-guardrails-1.json for your version).
aws ec2 create-vpc-block-public-access-exclusion \
  --region us-east-2 \
  --vpc-id <shared-prod-vpc-id> \
  --internet-gateway-exclusion-mode allow-bidirectional \
  --tag-specifications 'ResourceType=vpc-block-public-access-exclusion,Tags=[{Key=Reason,Value=CTIv7-SIP-Option-B}]'
```

> Prefer a subnet-scoped exclusion if your LZA/AWS version supports
> `--subnet-id` — that limits the exclusion to `shared-prod-public-a` instead of
> the whole VPC, which is tighter. Confirm the flag against the current API.

This step is intentionally **not** in the LZA config because LZA doesn't
manage per-VPC BPA exclusions declaratively in the pinned version. It's a
documented runtime prerequisite, tracked here.

## Apply order (this matters)

The pieces have a hard ordering. Out of order, you get partial failures.

1. **Part 1 (SCP)** and **Part 2 (network)** — merge together via the LZA
   pipeline. LZA applies the org policies and the VPC changes. ~60-90 min.
2. **Part 3 (BPA exclusion)** — runtime call after the IGW exists.
3. **AMI copy** — re-encrypt the CTI v7 AMI into us-east-2 (source is
   unencrypted). Independent of 1-3, can run in parallel.
4. **CTI v7 Terraform leaf** — only now. Its `apply` allocates the EIP, which
   the SCP (Part 1) must already permit and the public subnet (Part 2) must
   already exist to place the instance in.

If the leaf applies before Part 1, `AllocateAddress` is denied and the apply
fails partway (instance created, EIP not — a partial state to clean up). Don't.

## Verification

After Parts 1-2 apply:

```bash
# SCP took effect: the deny is now tag-scoped, not blanket
aws organizations describe-policy --policy-id <p-...> \
  --query 'Policy.Content' --output text | python3 -m json.tool | grep -A15 GRNETSEC2EIP

# IGW attached to shared-prod
aws ec2 describe-internet-gateways --region us-east-2 \
  --filters "Name=attachment.vpc-id,Values=<shared-prod-vpc-id>" \
  --query 'InternetGateways[].InternetGatewayId' --output text

# Public subnet exists and is shared to Production
aws ec2 describe-subnets --region us-east-2 \
  --filters "Name=tag:Name,Values=*shared-prod-public-a" \
  --query 'Subnets[].{Id:SubnetId,Cidr:CidrBlock,Az:AvailabilityZone}' --output table
```

After Part 3:

```bash
aws ec2 describe-vpc-block-public-access-exclusions --region us-east-2 \
  --query 'VpcBlockPublicAccessExclusions[].{Id:ExclusionId,Vpc:VpcId,Mode:InternetGatewayExclusionMode,State:State}' \
  --output table
```

**Critical apply-time check on the leaf:** the EIP must be tagged
`Migrated = CTIv7` **at creation**, because `GRNETSEC2EIPAllocate` keys on
`aws:RequestTag/Migrated`. The `ec2-migrated` module allocates the EIP via
`aws_eip` with `tags` set, and the AWS provider passes tags in the
`AllocateAddress` call (tag-on-create), so `RequestTag` is present. If a future
provider change split tagging into a separate `CreateTags` call, the allocate
would be denied. If the leaf's apply fails on `AllocateAddress` with an SCP
explicit-deny error, this is the first thing to check.

## Rollback

Reverse order:

1. Destroy the CTI v7 leaf (releases the EIP).
2. Delete the BPA exclusion:
   `aws ec2 delete-vpc-block-public-access-exclusion --exclusion-id <id>`.
3. Revert `network-config.yaml` (IGW back to `false`, remove the public subnet
   + route table) and revert the SCP (fold the two EIP statements back into
   `GRNETSEC2`). Run the LZA pipeline.

The IGW removal fails if the EIP is still associated to an instance in the
public subnet, so step 1 must come first.

## What was deliberately NOT done

- **No OU-wide change.** The SCP still applies to the whole Workloads/Prod OU,
  but the carve-out is tag-scoped, so only a `Migrated = CTIv7`-tagged resource
  benefits. Another team tagging a random EIP `Migrated = CTIv7` would inherit
  it — that's the residual risk of tag-scoping, accepted here as the standard
  LZA pattern (same shape the v8.6 CTI work planned).
- **No dedicated VPC.** We reused `shared-prod` with an additive public subnet
  rather than standing up a new VPC. Reversible with more effort if isolation
  requirements change later.
- **No change to the BPA declarative policy JSON.** It already allows
  exclusions; the exclusion itself is runtime.

## Files touched

| File | Change |
|---|---|
| `service-control-policies/lza-core-workloads-guardrails-1.json` | Moved `AllocateAddress`/`AssociateAddress` out of `GRNETSEC2` into tag-scoped `GRNETSEC2EIPAllocate` + `GRNETSEC2EIPAssociate`. |
| `network-config.yaml` (shared-prod VPC) | `internetGateway: true`; added `shared-prod-rt-public-a` route table and `shared-prod-public-a` /27 subnet, shared to Production. |
| (runtime, no file) | VPC BPA exclusion in the Network account. |
| `terraform/live/production/cti-v7/` | The leaf that consumes all of the above (separate PR, applied last). |

## See also

- `docs/07-Operations/cti-v7-migration-options.md` — the option analysis
- `eip-cross-org-migration-guide.md` — the general direct-EIP recipe
- `terraform/live/production/cti-v7/README.md` — the leaf's own prerequisites
- PCI VPC block in `network-config.yaml` — the in-repo precedent for a
  workload VPC with a public subnet + IGW route
