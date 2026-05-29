# Elastic IP Cross-Organization Migration Guide

Audience: LZA operator for `thenew-aws-accelerator-config`.
Goal: transfer an Elastic IP (EIP) from a source AWS account in **another organization** into an account inside this LZA org, then associate it with a resource that respects the existing guardrails (no public workload subnets, no IGW in workload VPCs).

> Read end-to-end before starting. The transfer is reversible up to the moment the receiver accepts; after that the EIP belongs to the destination account and the only way back is another transfer.

---

## 0. The strategy

You're going to:

1. **Pick a destination account inside this LZA org** that can actually use the EIP under existing SCPs and BPA. In practice this is the **Network** or **Perimeter** account (Ingress VPC for inbound, Egress VPC for outbound).
2. **Use the AWS-native EIP transfer feature** (`enable-address-transfer` / `accept-address-transfer`) to move the address from the foreign org's account to your destination account. This works across AWS Organizations as long as both accounts are in the same partition (e.g., both `aws`, both `aws-us-gov`).
3. **Land the EIP** on a supported resource:
   - **Inbound use case**: associate with an **NLB** in the Ingress VPC, target the private workload via TGW.
   - **Outbound use case**: associate with a **NAT Gateway** in the Egress VPC, all workload egress already flows there.
4. **Direct EC2 association is not viable** under the current config without breaking guardrails. See Section 7 if you must go that route.

End state:

- Same public IPv4 address, now owned by an account in your org.
- Downstream client's allowlist still works.
- No SCP exceptions, no BPA exclusions, no IGW added to workload VPCs.

### Why the destination matters

Three layers in `thenew-aws-accelerator-config` constrain where an EIP is usable:

| Layer | Effect | Where it applies |
|---|---|---|
| SCP `lza-infrastructure-guardrails-1` | Denies `ec2:AllocateAddress`, `ec2:AssociateAddress`, `ec2:AssociateNatGatewayAddress` for non-LZA principals | Network, Perimeter, SharedServices accounts |
| SCP `lza-core-workloads-guardrails-1` | Denies `ec2:AllocateAddress`, `ec2:AssociateAddress` for non-LZA principals | Workloads/Dev, Workloads/Test, Workloads/Prod OUs |
| SCP `lza-core-sandbox-guardrails-1` | Same denies, scoped by `Accelerator` resource tag | Workloads/Sandbox OU |
| Declarative policy `lza-core-vpc-block-public-access` | `internet_gateway_block: block_bidirectional` (with `exclusions_allowed`) | Security OU, Workloads/Dev/Test/Prod, Network and SharedServices accounts |
| `network-config.yaml` | `internetGateway: false` on all workload VPCs | Every shared workload VPC |

Net effect:

- **Workload accounts**: EIP can be received via transfer, but cannot be allocated by users, cannot be associated with anything, and there's no IGW for it to route through. Dead end.
- **Network / Perimeter account**: same SCP denies, but the **Ingress VPC** and **Egress VPC** were created by LZA roles and already have IGWs. NLBs and NAT Gateways provisioned through the LZA pipeline (i.e., as IaC under `cdk-accel*` / `AWSAccelerator-*` roles) can hold the EIP without violating SCPs.

So the destination is **Network** (Ingress VPC for NLB, Egress VPC for NAT) and the EIP gets associated through an LZA pipeline run, not by hand.

---

## 1. Pre-flight checklist

Before touching anything:

- [ ] You have **admin / break-glass access** to the source account in the foreign organization.
- [ ] You have **admin access** to the management account of this LZA org and to the **Network** account.
- [ ] You know the **EIP allocation ID** (e.g., `eipalloc-0123456789abcdef0`) and **public IP** in the source account.
- [ ] Source and destination accounts are in the **same AWS partition** (both standard `aws`, or both `aws-us-gov`).
- [ ] Source and destination accounts are in the **same region**. EIP transfer is region-scoped — it does not move the address across regions. If you need a region change, you can't keep the IP.
- [ ] The EIP is **not** a BYOIP address advertised from a public IPv4 pool that you don't control in the destination. (BYOIP pools have their own org-level transfer process; this guide covers regular EIPs.)
- [ ] The EIP is **not currently associated** with anything you care about, or you have a maintenance window to disassociate it. Transfer requires the EIP to be unassociated at the moment of `accept-address-transfer`.
- [ ] You have a **change window** and can run the LZA pipeline.
- [ ] Downstream clients that allowlist this IP have been notified of a brief disassociation window (typically 5–15 minutes).

Optional but recommended:

- [ ] Document the current EIP → ENI / instance binding in the source account so it can be reverted if the transfer fails before acceptance.

---

## 2. Choose the destination pattern

Pick one of these based on the use case. The rest of the guide assumes you've made this choice.

### Option A — Inbound: NLB in the Ingress VPC (recommended for "client connects to our service")

Use this when the third party allowlists your **inbound** IP.

- Destination account: **Network**
- Region: **{{ HomeRegion }}** (matches your existing Ingress VPC)
- Target resource: a new **Network Load Balancer** placed in the existing public subnets `{{ AcceleratorPrefix }}-{{ HomeRegion }}-ingress-public-a` and `{{ AcceleratorPrefix }}-{{ HomeRegion }}-ingress-public-b`.
- NLB targets: IP-type, pointing at the private workload EC2/ALB across the TGW.
- Result: same EIP serves traffic, workload stays in a private subnet with no IGW, no SCP exception needed.

If you need L7 features (host headers, paths, WAF) the chain becomes:
client → NLB (EIP) → private ALB in workload VPC → EC2.

### Option B — Outbound: EIP on the Egress NAT Gateway (recommended for "we connect to their service")

Use this when the third party allowlists your **outbound** IP.

- Destination account: **Network**
- Region: **{{ HomeRegion }}**
- Target resource: associate the EIP with one of the existing NAT Gateways (`{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-natgw-a` or `-b`).
- All workload egress already flows through these NAT GWs via TGW, so no workload-side change is required.
- Caveat: NAT GWs use a single EIP per AZ. If both AZs are already pinned, you'll either replace one of them (causes a brief egress flip) or accept that the third party is allowlisting one AZ's IP.

### Option C — Global Accelerator (alternative to A)

If the third party can switch to two anycast IPs that you control long-term, Global Accelerator is cleaner than per-AZ NLB EIPs and is portable across accounts. Out of scope for this guide because it doesn't actually keep the original EIP — it gives you new ones. Mentioned for completeness.

### Option D — Direct association on a workload EC2 (not supported by current guardrails)

See Section 7. Requires SCP exception, BPA exclusion, IGW added to a workload VPC. Last resort.

---

## 3. Transfer the EIP from the foreign org to the Network account

The mechanics are the AWS EIP transfer feature. Two CLI calls: one in the source account, one in the destination.

### Step 3a — Disassociate the EIP in the source account (if currently associated)

In the **source account** (foreign org), in the **same region** as the EIP:

```bash
aws ec2 describe-addresses --allocation-ids eipalloc-XXXXXXXXXXXXXXXXX --region us-east-1 --query "Addresses[0].{PublicIp:PublicIp,AssociationId:AssociationId,InstanceId:InstanceId,NetworkInterfaceId:NetworkInterfaceId}"
```

If `AssociationId` is non-null, disassociate:

```bash
aws ec2 disassociate-address --association-id eipassoc-XXXXXXXXXXXXXXXXX --region us-east-1
```

> The downstream service is reachable through this IP until you associate it on the destination side. Plan accordingly.

### Step 3b — Enable transfer in the source account

In the **source account**:

```bash
aws ec2 enable-address-transfer --allocation-id eipalloc-XXXXXXXXXXXXXXXXX --transfer-account-id 111111111111 --region us-east-1
```

Replace `111111111111` with the **destination account ID** (your Network account in this LZA org).

This puts the EIP into a `pending` transfer state. The address still belongs to the source account until the destination accepts. You have **7 days** to accept, after which the offer expires.

To check status:

```bash
aws ec2 describe-addresses --allocation-ids eipalloc-XXXXXXXXXXXXXXXXX --region us-east-1 --query "Addresses[0].{PublicIp:PublicIp,Status:NetworkBorderGroup,Transfer:PtrRecord}"
```

```bash
aws ec2 describe-address-transfers --allocation-ids eipalloc-XXXXXXXXXXXXXXXXX --region us-east-1
```

### Step 3c — Accept the transfer in the Network account

In the **Network account** (destination), **same region**, using a role that is **not** denied by `lza-infrastructure-guardrails-1`. This is the critical SCP point.

`AcceptAddressTransfer` is not in the SCP deny list, so any admin or break-glass principal can call it. But the resulting EIP, once accepted, is owned by the Network account and any subsequent `AllocateAddress` / `AssociateAddress` action falls under the SCP denies. Plan to do the association via LZA pipeline (Section 4 / 5), not by hand.

```bash
aws ec2 accept-address-transfer --address 203.0.113.42 --region us-east-1
```

> Note: `accept-address-transfer` takes the **public IP** as `--address`, not an allocation ID. The EIP is not yet a resource in your account when you accept.

The response returns the new allocation ID in the destination account, e.g., `eipalloc-0aaaa1111bbbb2222c`. Record this — you'll need it for Section 4 or 5.

Verify:

```bash
aws ec2 describe-addresses --filters "Name=public-ip,Values=203.0.113.42" --region us-east-1 --query "Addresses[0].{AllocationId:AllocationId,PublicIp:PublicIp,Domain:Domain,AssociationId:AssociationId}"
```

At this point the EIP exists in the Network account, unassociated.

---

## 4. Associate the EIP with an NLB (Option A)

This is done through LZA's customizations stack so the change is IaC and the LZA roles satisfy the SCP.

### 4a. Add an NLB to your ingress customizations stack

You already have `thenew-aws-accelerator-config/custom-stacks/ingress-alb.yaml`. Add (or extend with) a sibling stack `ingress-nlb-eip.yaml` that:

- Creates an internet-facing NLB.
- Places it in the existing Ingress VPC public subnets.
- Uses **subnet mappings** with `AllocationId` set to the imported EIP allocation ID.
- Defines a target group of type `ip` pointing at the private workload IP(s) in the workload VPC.

Skeleton (replace the placeholders):

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: Ingress NLB with imported EIP

Parameters:
  EipAllocationIdAzA:
    Type: String
    Description: Allocation ID of the EIP transferred from the foreign org (AZ a)
  IngressVpcId:
    Type: AWS::EC2::VPC::Id
  IngressPublicSubnetA:
    Type: AWS::EC2::Subnet::Id
  IngressPublicSubnetB:
    Type: AWS::EC2::Subnet::Id
  WorkloadTargetIp:
    Type: String
    Description: Private IP of the workload EC2 reachable via TGW
  ListenerPort:
    Type: Number
    Default: 443

Resources:
  IngressNlb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: ingress-nlb-migrated-eip
      Type: network
      Scheme: internet-facing
      SubnetMappings:
        - SubnetId: !Ref IngressPublicSubnetA
          AllocationId: !Ref EipAllocationIdAzA
        - SubnetId: !Ref IngressPublicSubnetB
          # Optional: pin AZ b with a second EIP if the client allowlists both AZs.

  WorkloadTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: workload-tg
      TargetType: ip
      Protocol: TCP
      Port: !Ref ListenerPort
      VpcId: !Ref IngressVpcId
      Targets:
        - Id: !Ref WorkloadTargetIp
          Port: !Ref ListenerPort

  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref IngressNlb
      Protocol: TCP
      Port: !Ref ListenerPort
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref WorkloadTargetGroup
```

> If the third party allowlists both AZs, transfer a second EIP using the same procedure and add `AllocationId` to the AZ b subnet mapping.

### 4b. Wire it into `customizations-config.yaml`

Add a `customizations.cloudFormationStacks` entry that:

- `deploymentTargets.accounts: [Network]`
- `regions: [{{ HomeRegion }}]`
- `template: custom-stacks/ingress-nlb-eip.yaml`
- `parameters` populated with the allocation ID from Section 3c, the Ingress VPC ID, and the public subnet IDs.

Use SSM parameter lookups or `replacements-config.yaml` so the allocation ID isn't hardcoded if you'd rather treat it as config.

### 4c. Zip and run the pipeline

- Zip the contents of `thenew-aws-accelerator-config/` (not the folder itself).
- Upload `aws-accelerator-config.zip` to the LZA config S3 bucket.
- CodePipeline → AWSAccelerator-Pipeline → Release change.

Pipeline runs as `AWSAccelerator-*` and `cdk-accel*` roles, which are explicitly allowed in the `ArnNotLike` of the SCP, so the NLB creation and EIP association succeed.

### 4d. Verify

- AWS Console → EC2 → Elastic IPs in the Network account → the EIP shows associated to the NLB's network interface.
- `dig` / `nslookup` the public IP from outside, confirm the NLB responds on the listener port.
- From the third party's side: confirm their allowlist still works (same IP, only the resource behind it changed).
- From a workload host, confirm health checks are green on the target group.

---

## 5. Associate the EIP with the Egress NAT Gateway (Option B)

This path replaces (or supplements) the EIP that LZA assigned to a NAT Gateway.

### 5a. Decide the AZ binding

Look at your current Egress NAT GW EIPs:

```bash
aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values={{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-natgw-a,{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-natgw-b" --region us-east-1
```

Each NAT GW already has an EIP associated. Replacing the EIP on an existing NAT GW requires recreating the NAT GW (NAT GW EIP is immutable post-create), which causes an egress blip for all workloads in that AZ. Plan accordingly.

### 5b. Update `network-config.yaml`

In `vpcs[].natGateways` for the Egress VPC, add `allocationId` (or `eip:` block depending on LZA version) referencing the imported EIP. Example shape:

```yaml
    natGateways:
      - name: "{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-natgw-a"
        subnet: "{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-a"
        allocationId: eipalloc-0aaaa1111bbbb2222c
      - name: "{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-natgw-b"
        subnet: "{{ AcceleratorPrefix }}-{{ HomeRegion }}-egress-public-b"
```

> Confirm the exact key in your LZA version. Some versions use `allocationIds` as a list, some use a `eip:` sub-block. Check the LZA config schema for the version pinned in `global-config.yaml`.

### 5c. Run the pipeline

- Zip → upload → release change as in Section 4c.
- LZA destroys the existing NAT GW in AZ a (egress drops in that AZ for ~2–5 minutes), creates a new one with the imported EIP.

### 5d. Verify

- New NAT GW status `available`.
- `curl ifconfig.me` from a workload EC2 in AZ a returns the migrated public IP.
- The orphan EIP that LZA originally created on this NAT GW is now unassociated; release it manually if you want to stop paying the unattached-EIP charge.

---

## 6. Tag and document the imported EIP

Even though the SCP for the Network account requires LZA roles to allocate or associate, **tagging an existing EIP** is allowed (it's `ec2:CreateTags`, not in the deny list). Add tags so future-you knows this EIP is special:

```bash
aws ec2 create-tags --resources eipalloc-0aaaa1111bbbb2222c --tags Key=Origin,Value=ImportedFromForeignOrg Key=SourceAccount,Value=999999999999 Key=ImportedDate,Value=2026-05-26 Key=Owner,Value=YourTeam --region us-east-1
```

If LZA's tag policy enforces specific tag keys, follow that schema instead.

Record in your runbook:
- Old EIP allocation ID and source account (gone after transfer accepted).
- New EIP allocation ID in the Network account.
- Public IP (unchanged).
- Resource it's attached to (NLB ARN or NAT GW ID).

---

## 7. Last resort — direct EIP on a workload EC2

Skip this section unless options A and B genuinely don't fit. This requires breaking three guardrails in a controlled way, and it's a permanent posture change for the affected account.

What you'd need:

1. **SCP exception**: add a new SCP that exempts a specific role in the workload account from the `AllocateAddress` / `AssociateAddress` deny, or move the account to a new OU with a relaxed SCP.
2. **VPC BPA exclusion**: BPA is set to `block_bidirectional` with `exclusions_allowed: enabled`. Create a per-VPC or per-subnet exclusion in that account.
3. **IGW in the workload VPC**: the existing workload VPC has `internetGateway: false`. You'd update `network-config.yaml` for that VPC, plus add a public subnet, public route table, and IGW route. This re-shapes the VPC topology and exposes the architecture to the kind of issues the hub-and-spoke design exists to prevent.

Implications:

- The workload VPC is now internet-facing in a way no other workload VPC is. Pen-test scope expands. Compliance posture changes.
- Anyone with EC2 admin in that account can now spin up additional public-IP instances by default.
- The SCP exception is a permanent attack surface; revoking it is straightforward but requires another pipeline run and any work that depends on it breaks.

If after weighing this the answer is still "yes, do it":

1. Create a new SCP `lza-workload-eip-exception-1.json` that allows `ec2:AllocateAddress`, `ec2:AssociateAddress`, `ec2:DisassociateAddress`, `ec2:ReleaseAddress` for a specific role ARN in the affected account.
2. Attach it as an account-targeted policy in `organization-config.yaml` rather than at OU level.
3. Update `network-config.yaml` to add a public subnet + IGW for the affected workload VPC.
4. Add a BPA exclusion via console or AWS CLI in that account: `aws ec2 create-vpc-block-public-access-exclusion --vpc-id vpc-xxxx --internet-gateway-exclusion-mode allow-bidirectional`.
5. Run the LZA pipeline.
6. In the workload account, accept the address transfer (Section 3c, but using the workload account ID instead of Network).
7. Associate the EIP with the EC2 ENI.

This is essentially a four-step departure from the design. Strongly prefer A or B.

---

## 8. Rollback playbook

| When | What |
|---|---|
| Before `accept-address-transfer` | In the source account, run `aws ec2 disable-address-transfer --allocation-id <id>`. The EIP stays in the source account, no harm done. |
| After accept, before NLB / NAT GW association | The EIP is in the Network account, unassociated. To send it back, call `enable-address-transfer` from the Network account back to the source account. The source account then accepts. Same procedure, mirrored. |
| After NLB association (Option A) | Disassociate from the NLB (or delete the NLB if it was created just for this). EIP remains in Network account, unassociated. Then transfer back if needed. |
| After NAT GW change (Option B) | Revert `network-config.yaml` to the prior state and run the pipeline. LZA recreates the NAT GW with a fresh LZA-managed EIP. The imported EIP is left unassociated — release or transfer back. |
| Section 7 | Reverse the SCP, BPA, and `network-config.yaml` changes in that order. The IGW removal will fail if the EIP is still associated to an EC2 in the public subnet — disassociate first. |

If the **transfer offer expires** (7 days) before acceptance: the EIP stays put in the source account, no action needed. Restart the procedure with a fresh `enable-address-transfer`.

---

## 9. Files you will touch

| Step | File | What changes |
|---|---|---|
| Section 4 (Option A) | `thenew-aws-accelerator-config/custom-stacks/ingress-nlb-eip.yaml` (new) | New CFN stack for the NLB |
| Section 4 (Option A) | `thenew-aws-accelerator-config/customizations-config.yaml` | Register the new stack, target Network account, region {{ HomeRegion }} |
| Section 5 (Option B) | `thenew-aws-accelerator-config/network-config.yaml` | Add `allocationId` to the relevant `natGateways` entry |
| Section 7 (last resort) | `thenew-aws-accelerator-config/service-control-policies/` (new file) + `organization-config.yaml` + `network-config.yaml` | SCP exception, BPA exclusion, IGW addition |

Files **not** touched for Options A and B:

- `service-control-policies/*` — no SCP changes required.
- `declarative-policies/lza-core-vpc-block-public-access.json` — no BPA changes required.
- `iam-config.yaml`, `security-config.yaml`, `accounts-config.yaml`, `global-config.yaml`.

---

## 10. Estimated timeline

| Phase | Duration |
|---|---|
| Section 1 pre-flight + alignment with third party | 30–60 min |
| Section 3 transfer (CLI calls + propagation) | 5–10 min |
| Brief disassociation window (downstream IP unreachable) | 5–15 min |
| Section 4 NLB stack + pipeline run (Option A) | 1–2 hours |
| Section 5 NAT GW pipeline run (Option B) | 1–2 hours, plus ~5 min egress blip per AZ |
| Section 6 tagging + runbook update | 10 min |

Total active engineering time: **~2 hours of work**, plus pipeline waits.

---

## 11. Quick reference — final state

**After Option A (Inbound NLB):**
- EIP owned by Network account in {{ HomeRegion }}.
- Associated to a new NLB in the Ingress VPC public subnets.
- NLB targets the private workload via TGW.
- Same public IP, downstream allowlist intact.
- No SCP exceptions, no BPA exclusions, no IGW added to workload VPCs.

**After Option B (Outbound NAT):**
- EIP owned by Network account.
- Pinned to one of the Egress NAT Gateways.
- All workload egress in that AZ exits with the migrated public IP.
- Original LZA-assigned EIP for that NAT GW is orphaned — release manually.

**After Option C (Global Accelerator):**
- Different IPs, two anycast addresses, account-portable. Out of scope for this guide.

**After Option D (Section 7 last resort):**
- EIP on a workload EC2.
- One workload account has SCP exception, BPA exclusion, IGW on a workload VPC. Permanent posture change.

---

## 12. References

- AWS — Transfer Elastic IP addresses: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/vpc-eips.html#transfer-EIPs-intro
- AWS CLI — `enable-address-transfer`: https://docs.aws.amazon.com/cli/latest/reference/ec2/enable-address-transfer.html
- AWS CLI — `accept-address-transfer`: https://docs.aws.amazon.com/cli/latest/reference/ec2/accept-address-transfer.html
- AWS CLI — `describe-address-transfers`: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-address-transfers.html
- AWS — VPC Block Public Access: https://docs.aws.amazon.com/vpc/latest/userguide/security-vpc-bpa.html
- LZA — Customizations config: https://awslabs.github.io/landing-zone-accelerator-on-aws/latest/user-guide/config/
