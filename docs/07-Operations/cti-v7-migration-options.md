# CTI v7 — Migration Options

Decision document for how to migrate the **CTI v7** server out of the source tenant (`254422596287`, `us-east-1`) alongside the rest of the CTI v7 cluster (WS Aheeva, Webapps Server, Webapps PHP 7.3, RDS `iccmaindb`).

The other three servers and the RDS are unaffected by this decision — their migration path is settled and documented in `cti-v7-cluster-migration-plan.md`. This document only covers the CTI v7 box itself, because CTI v7 is the one server in the cluster whose network shape may not survive the move into a standard LZA workload spoke.

## Why CTI v7 needs its own decision

Three things separate CTI v7 from the other servers in this cluster:

1. **CTI v7 may carry SIP traffic** (voice signaling and RTP media). The other three servers are HTTP-only or internal-only. SIP traffic is sensitive to NAT and to what public IP an endpoint sees itself as, which the source-tenant flat-VPC layout handles trivially and which the destination hub-and-spoke layout does not.
2. **CTI v7 may need a stable, direct public IP.** If SIP carriers or partners connect *inbound* to CTI v7 and allowlist its IP, the migration has to preserve some form of stable public endpoint that CTI v7 can also advertise back to the far side in SDP.
3. **CTI v7 only talks to `iccmaindb` indirectly, through WS Aheeva.** That means CTI v7 does not strictly need to live in the same account as the migrated RDS. It just needs a network path to WS Aheeva. That opens the door to option C (leave in source, reach WS Aheeva remotely) that isn't available for the DB-touching servers.

The correct option depends on facts we don't know yet: whether SIP is in scope at all, and if so who initiates connections, whether media hits this box directly, and what the carriers' allowlist story is.

## Facts to nail down before choosing

Answering these picks the option for us. Until they're answered we're speculating.

- **Does CTI v7 handle SIP traffic today?** Or is it a pure worker that WS Aheeva calls into over HTTP?
- **If yes, direction:** Does CTI v7 send outbound `REGISTER` to carriers (we register to them), or do carriers send inbound `INVITE` to CTI v7's public IP (they connect to us), or both?
- **Media (RTP) topology:** Does RTP flow directly to/from CTI v7's public IP, or is there a media gateway / SBC in between? Which UDP port range?
- **Partner allowlists:** Does anything on the other side allowlist CTI v7's current public IP for SIP or otherwise?
- **Current public IP:** What is it, is it an Elastic IP, and how many partners are pinned to it?
- **User-facing UI:** Does anyone hit CTI v7 directly on TCP (agent client, admin UI, etc.) or is all human traffic via WS Aheeva / the Webapps?

If SIP is not in play and CTI v7 is a pure internal worker, this document collapses to **Option A** and we're done.

## The three options

### Option A — Standard workload spoke (private, no exception)

Migrate CTI v7 into `shared-prod` as a private EC2 in the app-a subnet, same shape as WS Aheeva and the two webapps. No IGW in the workload VPC, no public IP on the instance, no SCP exception. WS Aheeva reaches it over the VPC.

**What changes vs source:**
- CTI v7 has no public IP. Every external inbound path is gone.
- Egress goes TGW → perimeter Egress VPC → NAT GW. Outbound public IP is the NAT GW EIP, not CTI v7's own.
- Admin access is SSM Session Manager or EC2 Instance Connect Endpoint.

**What stays the same:**
- WS Aheeva → CTI v7 traffic (probably HTTP or a private protocol) works over private VPC routing.
- Anything CTI v7 initiates outbound still works; the destination just sees the NAT GW EIP instead of the old public IP.

**Risks and constraints:**
- **SIP inbound breaks.** No inbound anything on 5060 or the RTP range from the public internet.
- **SIP outbound `REGISTER`** may work but the far side sees the NAT GW EIP, not CTI v7's own IP. If the SIP peer authenticates on source IP or hardcodes it into its own allowlist, we have to coordinate that change with the peer.
- **RTP one-way audio risk** — a classic problem when a SIP endpoint sits behind NAT it doesn't know about. Aheeva has `externip` / `external_media_address` config for this; would need to be set to a stable public IP we can advertise. NAT GW EIPs are stable, but the mapping between UDP source ports on the instance and what the peer sees through the NAT GW is not deterministic for arbitrary UDP flows, which is what breaks RTP.
- **No stable inbound public endpoint** unless we front CTI v7 with an NLB in the perimeter (which is fine for TCP-based SIP but does not solve RTP media).

**When Option A works:**
- CTI v7 has no SIP traffic — it's an internal worker behind WS Aheeva.
- CTI v7 has SIP but only outbound `REGISTER` to a carrier that authenticates by username/password and doesn't care about source IP.
- SIP traffic can be reshaped through an SBC we already have or are willing to add.

**When Option A does not work:**
- Carriers send inbound `INVITE` to CTI v7's public IP.
- RTP media terminates on CTI v7 directly (no SBC).
- Partners have hardcoded CTI v7's current public IP in their allowlists and cannot update.

**Effort:** Same as WS Aheeva and the webapps. AMI export → new Terraform leaf `terraform/live/production/cti-v7/` using `terraform/modules/ec2-migrated` → deploy → point WS Aheeva at it.

**Effort visible to the client:** SIP peers are told there's no change unless they had CTI v7 in an allowlist, in which case they get the NAT GW EIP for outbound and (if inbound is a thing) a new NLB DNS name.

### Option B — Migrate to `shared-prod` with a scoped exception (direct EIP on CTI v7)

Migrate CTI v7 into `shared-prod` but keep the source-tenant network shape: CTI v7 sits in a public subnet in its own VPC (or in a dedicated public subnet added to `shared-prod`'s VPC), has a direct Elastic IP, and takes SIP/RTP traffic directly. Achieved by adding a narrow, tag-scoped exception to the LZA guardrails that normally block that shape.

**What changes vs source:**
- Account changes to `shared-prod`, region changes to `us-east-2`.
- New Elastic IP (Lightsail-style stable-IP move isn't possible cross-region cross-org unless we use `eip-cross-org-migration-guide.md` to transfer the exact IP; even then it's a one-way move).

**What stays the same:**
- CTI v7 has a public IP directly on its ENI. `externip` in Aheeva config = its own EIP. No NAT translation to reason about.
- SIP inbound `INVITE` and outbound `REGISTER` work identically to today.
- RTP media flows directly between the SIP peer and CTI v7. No one-way audio surprises from NAT.

**Risks and constraints:**
- **Multi-piece exception** — this is not a single toggle. Four things have to change and stay changed:
  1. **SCP exception.** The workload OU SCP `lza-core-workloads-guardrails-1` denies `ec2:AllocateAddress` and `ec2:AssociateAddress` for non-LZA principals. We add a per-account (or per-role, or per-resource-tag) exception. Documented pattern from the v8.6 questionnaire uses a resource tag like `Migrated == CTIv7` (or whatever we choose) to scope the exception to exactly this one server.
  2. **VPC Block Public Access exclusion.** The declarative policy `lza-core-vpc-block-public-access` blocks bidirectional IGW attachment. Set `exclusions_allowed: enabled` for the affected VPC and add a per-VPC exclusion.
  3. **IGW in the workload VPC.** `network-config.yaml` for `shared-prod` currently has `internetGateway: false`. Add an IGW, a public subnet, and a public route table. Requires an LZA pipeline run.
  4. **Terraform allow-policy** — `aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json` already lists `AllocateAddress` / `AssociateAddress`, so Terraform can call them once the SCP allows it.
- **Blast radius of the exception is not zero.** The SCP exception ideally scopes to a resource tag but if someone tags a new EC2 with the same value, they inherit the exception. Tag drift is real.
- **`shared-prod` becomes a partially-internet-facing account.** Other workloads in the same account are protected by the tag-scoping, but the account's audit posture is different from a pure private-only account.
- **Every one of the four changes above lands via a separate PR** — three of them touch LZA config, so they run through the LZA pipeline (batched with any other pending LZA changes, which slows the cutover). The Terraform-managed pieces (EIP allocation, ENI association) run through the normal CI plan/apply cycle.
- **Permanent posture change.** The exception is not "for the cutover window." It's structural. Removing it later requires another LZA pipeline run and the CTI v7 SIP shape breaks the moment it's removed.

**When Option B works:**
- SIP inbound / direct RTP is genuinely required and cannot be reshaped through an SBC.
- The client accepts the audit-posture change on `shared-prod`.
- There is appetite to run three LZA-pipeline PRs (SCP, VPC BPA exclusion, network config) plus the Terraform PR for the EIP.

**When Option B does not work:**
- The compliance posture forbids IGW-attached workload VPCs.
- We cannot get the LZA pipeline changes reviewed and applied on the timeline the client needs.

**Effort:** Substantially more than Option A. Three LZA-pipeline PRs plus the Terraform leaf. Each LZA PR runs through the accelerator pipeline which takes ~60-90 minutes end-to-end per run. Sequencing matters — the SCP has to be in place before the Terraform apply that allocates the EIP or the apply fails.

**Precedent in this repo:** the exact same shape was mapped out for **CTI v8.6** (a different Aheeva migration) in `docs/07-Operations/aheeva-migration-questionnaire.md` Section 7 Option A. That work has not been executed; this migration could either share the exception (scoping the SCP tag to match both servers) or add a second one specific to CTI v7. Recommended: separate exceptions per server, so removing one doesn't accidentally break the other.

### Option C — Leave CTI v7 in the source tenant

Do not migrate CTI v7. Migrate WS Aheeva, the two webapps, and RDS `iccmaindb` as planned. Configure the migrated WS Aheeva to reach CTI v7 in the source tenant across the public internet, using CTI v7's existing public IP.

**What changes vs source:**
- The three other servers plus RDS move to the new tenant per `cti-v7-cluster-migration-plan.md`.
- WS Aheeva (in the new tenant) reaches CTI v7 (in the source tenant) via CTI v7's public IP. Outbound from WS Aheeva goes through the perimeter NAT GW EIP. CTI v7's security group has to allowlist the NAT GW EIP on whatever port WS Aheeva uses.
- Nothing about CTI v7's SIP topology changes.
- The source tenant stays alive indefinitely for CTI v7's sake.

**What stays the same:**
- CTI v7 keeps its current public IP, its current SIP shape, its current SG rules.
- SIP peers see no change.

**Risks and constraints:**
- **Ongoing cost of the source tenant.** The account is not fully decommissioned. Baseline account costs (guardrails, config recorder, CloudTrail, etc.) continue.
- **Two-tenant operational surface.** Debugging cross-tenant issues requires switching credentials. Monitoring, logging, patching, and IAM management stay split. Runbooks have to note which tenant each service lives in.
- **CTI v7 sits on a legacy account posture.** The source-tenant SG for `iccmaindb`-adjacent resources currently has 18 public-IP allowlist entries and probably other legacy findings we haven't audited. The migration cleans that up for the other servers; CTI v7 stays in the mess unless we do a security-hardening pass in place.
- **CTI v7 → migrated WS Aheeva traffic egresses to the internet** on both sides. Fine functionally, but it's a hop through the internet for what should logically be an internal call. Latency is a rounding error at these distances (us-east-1 ↔ us-east-2 < 15ms round trip); the issue is trust boundary and observability, not performance.
- **Security hardening in place must actually happen.** The rationale for Option C hinges on "we'll apply best practices in the source tenant." If that work slips, we've left CTI v7 permanently exposed on the source-tenant SG.
- **RDS access.** CTI v7 doesn't talk to RDS directly today, only via WS Aheeva. Confirm this in a call trace before locking Option C — if any code path on CTI v7 does open a MySQL connection to `iccmaindb`, Option C requires that CTI v7 also reach the migrated RDS, which either means keeping the RDS publicly accessible in the destination (defeating one of the migration's benefits) or setting up an inter-tenant network path (VPN, TGW peering, or PrivateLink). If truly no direct connection exists, this concern goes away.

**Source-tenant hardening to do if Option C is chosen:**

- Trim the 18 public IPs on `sg-3003a540` down to the minimum still needed.
- Restrict CTI v7's own security group to just the sources it needs (SIP peers, WS Aheeva NAT GW EIP, admin IPs).
- Enable AWS Systems Manager Session Manager on CTI v7 so admin access no longer relies on `0.0.0.0/0` SSH.
- Turn on CloudTrail data events, VPC Flow Logs, and GuardDuty in the source account if they aren't already.
- Rotate any long-lived IAM keys in the source account, prefer SSO-federated access.
- Take a fresh application-consistent AMI monthly and keep the most recent three, for DR purposes.

**When Option C works:**
- CTI v7 does not open direct MySQL connections to `iccmaindb`.
- SIP shape is direct-EIP-and-preserve-source-IP and Option B is not palatable.
- The client accepts the ongoing operational cost of running two AWS accounts long-term.

**When Option C does not work:**
- The migration mandate is "fully decommission the source tenant." Option C can't deliver that.
- CTI v7 opens a direct MySQL connection to `iccmaindb`.

**Effort:** Least effort in the new tenant. Most effort in "operational tax" of keeping two accounts alive. No LZA pipeline changes.

## Comparison at a glance

| Dimension | Option A: Private in shared-prod | Option B: Exception in shared-prod | Option C: Leave in source |
|---|---|---|---|
| CTI v7 has a public IP | No | Yes, direct EIP | Yes (unchanged) |
| Handles inbound SIP `INVITE` from carriers | No | Yes | Yes (unchanged) |
| RTP direct media | No | Yes | Yes (unchanged) |
| Source tenant fully decommissioned | Yes | Yes | No |
| LZA guardrail changes required | None | SCP + BPA + IGW + network-config | None |
| Number of PRs to open | 1 Terraform | 1 Terraform + 3 LZA | 0 |
| Blast radius of security posture change | None | Tag-scoped exception on `shared-prod` | None (source tenant remains legacy) |
| Ongoing multi-account tax | No | No | Yes |
| Effort to reverse decision later | High (re-migrate) | Medium (remove exception, re-migrate to Option A) | Medium (migrate as Option A or B) |
| Cutover risk on CTI v7 | Low (if no SIP) / High (if SIP present) | Low (identical network shape to source) | Trivial (nothing moves) |
| Risk of one-way audio / SIP breakage | High if SIP is in play | Low | None |
| WS Aheeva ↔ CTI v7 traffic path | Private VPC | Private VPC | Public internet (NAT GW EIP ↔ CTI v7 public IP) |

## Recommendation (subject to the fact-finding questions)

Ordered by our default preference, assuming we don't yet know whether SIP is in play:

1. **If CTI v7 does not carry SIP traffic → Option A.** The whole rationale for B and C is SIP. Without SIP, this is a boring lift-and-shift.
2. **If CTI v7 carries SIP but only outbound registration → Option A, with the caveat that we coordinate the outbound source IP change with the SIP peer.** Adding an SBC in front is another sub-option we haven't broken out but is reasonable.
3. **If CTI v7 handles inbound SIP `INVITE` or direct RTP → Option B.** Accept the guardrail exception in exchange for a network shape SIP is known to survive. The v8.6 questionnaire already mapped this out; we'd reuse the pattern.
4. **Option C is the fallback if Option B is politically or compliance-blocked** and Option A is technically blocked. It works, but it costs long-term.

**Not recommended:** trying to make Option A work with SIP by chaining ALBs, NLBs, and Global Accelerator. NLBs can carry TCP SIP, and Global Accelerator provides a stable anycast IP, but RTP media is UDP and stateful in ways NLBs handle poorly. Every deployment that goes down this path ends up either (a) adding an SBC anyway, or (b) migrating to a direct-EIP shape. Better to skip the intermediate step.

## Decision criteria checklist

For the reviewer / decision-maker, in order:

- [ ] Does CTI v7 carry SIP traffic today? If **no**, choose Option A. Stop reading.
- [ ] Is SIP inbound or only outbound registration? If **outbound-only** and the carrier tolerates a source-IP change, choose Option A.
- [ ] Is RTP media direct to CTI v7 or does an SBC / media proxy sit between? If an **SBC exists**, choose Option A (the SBC absorbs NAT).
- [ ] Is the client willing to run three LZA-pipeline PRs (SCP + BPA + network-config) to create the exception? If **yes**, choose Option B. If **no**, choose Option C.
- [ ] Is fully decommissioning the source tenant a hard requirement? If **yes**, Option C is off the table — you must land on A or B.
- [ ] Does CTI v7 open MySQL connections directly to `iccmaindb`? If **yes**, Option C is off the table (RDS is moving to the new tenant).

## Next steps regardless of option

- Ask the client the six fact-finding questions at the top of this document.
- If SIP is in scope, get a copy of `sip.conf` / `pjsip.conf` from CTI v7 (or the equivalent config file for whatever SIP stack it runs). The exact `externip`, `nat`, `localnet`, `rtpstart`, `rtpend` values determine whether Option A can survive with tweaks or genuinely can't.
- Get the current CTI v7 EC2 details (instance ID, type, size, current EIP, current SG rules). Feeds either option.

## References

- `cti-v7-cluster-migration-plan.md` — the overall plan for the four-server cluster; this document is a decision point within it.
- `docs/07-Operations/aheeva-migration-questionnaire.md` — the CTI v8.6 questionnaire, which mapped out an equivalent exception pattern for a different server. Section 7 covers direct-EIP-on-EC2 and its guardrail implications.
- `eip-cross-org-migration-guide.md` — canonical writeup of the SCP + BPA + IGW work required for a direct-EIP-on-workload-EC2 shape. Section 7 of that doc is the concrete recipe if we land on Option B.
- `aws-accelerator-config/service-control-policies/lza-core-workloads-guardrails-1.json` — the workload SCP that has to be exempted for Option B.
- `aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json` — the Terraform allow-policy that already permits `AllocateAddress` / `AssociateAddress` (so the constraint really is the SCP, not Terraform).
- `terraform/live/production/sftp-server/` — reference leaf pattern that Option A would model itself on.
