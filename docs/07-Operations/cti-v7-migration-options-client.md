# CTI v7 — Migration Options

Overview of the paths available for moving the **CTI v7** server as part of the broader migration of your CTI v7 cluster (CTI v7, WS Aheeva, the two web application servers, and the `iccmaindb` MySQL database) from the current AWS account into the new one.

The other three servers and the database have a settled migration path. This document is only about CTI v7, because it is the one server in the cluster whose network profile may not fit cleanly into the new environment without a decision from your side.

## Why CTI v7 needs a separate conversation

Three things set CTI v7 apart from the other servers being moved:

1. **CTI v7 may handle SIP traffic** (voice signaling and RTP media). The other servers in the cluster are HTTP-based or purely internal. SIP is sensitive to how public IP addresses are handled and to network address translation, both of which look different in the new environment than they do today.
2. **CTI v7 may need a stable, directly attached public IP.** If any of your voice carriers or partners have added CTI v7's current public IP to an allowlist, or if inbound SIP calls arrive at that IP directly, we need to keep some form of stable public endpoint that also works for the SIP protocol.
3. **CTI v7 only talks to the database through WS Aheeva.** It does not open a direct connection to `iccmaindb`. That gives us a third option that isn't available for the other servers: leaving CTI v7 where it is and letting the migrated WS Aheeva reach it over the public internet.

The correct choice depends on facts we do not yet have. Until we do, we are working from assumptions.

## Questions we need answered

Answering these picks the option for us:

1. Does CTI v7 handle SIP traffic today, or is it a pure worker that only WS Aheeva talks to over HTTP?
2. If SIP is in play, who initiates the connection? Does CTI v7 send outbound `REGISTER` requests to carriers, or do carriers send inbound `INVITE` requests to CTI v7's public IP? Or both?
3. Does RTP media flow directly between CTI v7 and the far-side SIP peer, or is there a session border controller or media gateway between them?
4. Does anything on your partners' side pin CTI v7's current public IP in an allowlist?
5. Is there a user interface on CTI v7 that anyone connects to directly, or is all human traffic routed through WS Aheeva or the web apps?
6. Does CTI v7 ever open a direct MySQL connection to `iccmaindb`, or is every database interaction routed through WS Aheeva?

If CTI v7 does not handle SIP traffic and does not connect directly to the database, this decision is straightforward and lands on Option A below.

## The three options

### Option A — Move CTI v7 into the new environment as a private server

Migrate CTI v7 into the same new-environment account as WS Aheeva and the web apps, in the same private network. No public IP on the instance itself. WS Aheeva reaches it over the internal network. Any outbound traffic CTI v7 initiates exits through the shared internet gateway of the new environment.

**What changes compared to today:**

- CTI v7 has no directly attached public IP. Anything that used to reach it from the public internet no longer can.
- When CTI v7 makes outbound connections, the far side sees a shared public IP (belonging to the new environment's internet gateway), not CTI v7's own.
- Administrative access moves to AWS Systems Manager Session Manager or a controlled entry point — no more SSH from allowlisted IPs.

**What stays the same:**

- WS Aheeva reaches CTI v7 over the private network in the new environment.
- Outbound calls CTI v7 makes to external services continue to work, subject to any partner-side allowlist updates for the new outbound IP.

**Risks and constraints:**

- Inbound SIP breaks completely. Nothing on the public internet can dial in to CTI v7 anymore.
- Outbound SIP registration works, but the SIP peer will see the shared outbound IP of the new environment, not CTI v7's current IP. If the peer authenticates by IP or has hardcoded CTI v7's IP in an allowlist, that has to be renegotiated with the peer.
- If RTP media terminates directly on CTI v7 today, there is a real risk of one-way audio after the move, because the instance no longer sees itself at a public IP. Aheeva's `externip` setting can compensate, but only when we can hand it a stable, routable address for it to advertise.

**When Option A fits:**

- CTI v7 carries no SIP traffic and is purely an internal worker for WS Aheeva.
- CTI v7 carries SIP but only outbound registration to a carrier that authenticates by username and password and does not care about source IP.
- Your SIP infrastructure already has a session border controller in front of CTI v7 that absorbs the address translation.

**When Option A does not fit:**

- Carriers or partners initiate inbound SIP calls directly to CTI v7's public IP.
- RTP media terminates on CTI v7 with no intermediary.
- Partners cannot update their allowlists on any timeline that works for you.

**Effort:** Lowest of the three options. Same shape as the other server migrations we are doing.

### Option B — Move CTI v7 into the new environment, with a scoped exception so it keeps behaving like it does today

Move CTI v7 into the same new-environment account as the rest of the cluster, but keep the network shape that CTI v7 has today: a directly attached public IP, direct SIP and RTP flow, no address translation between the instance and its peers. This requires a controlled exception to the security guardrails that normally govern the new environment.

**What changes compared to today:**

- The AWS account and region change. Any partner that had CTI v7's old public IP in an allowlist needs to accept a new one — public IPs cannot be transferred across regions, so this is unavoidable in any migration option.

**What stays the same:**

- CTI v7 has a public IP directly on its network interface. Aheeva's `externip` points at that IP, exactly as today.
- Inbound SIP and outbound SIP work the same way they do now.
- RTP media flows directly between the SIP peer and CTI v7. No address translation between them.

**Risks and constraints:**

- **The exception is a permanent, not temporary, change.** The new environment is designed to prevent workload servers from having directly attached public IPs. Making CTI v7 an exception is not a checkbox — it requires several coordinated configuration changes and it stays in place for as long as CTI v7 is there.
- **The exception is narrowly scoped, but the account's security posture does shift.** We can scope the exception to CTI v7 specifically, using resource tagging, so that other workloads in the same account remain protected. That is well within our practice, but it is a real change to the audit story for that account.
- **The exception takes coordinated work to put in place.** Multiple pieces of the guardrail environment have to be updated together. This is meaningful engineering effort, and the changes are subject to your normal review process.
- **Reversibility is medium.** Removing the exception later is straightforward but requires another round of coordinated changes, and CTI v7's SIP shape breaks the moment it is removed.

**When Option B fits:**

- Inbound SIP and direct RTP are genuinely required and cannot be reshaped through an intermediary.
- Your compliance and security posture accepts a scoped, tag-limited exception to the workload guardrails on this account.
- You want the source AWS account fully decommissioned after the migration.

**When Option B does not fit:**

- Your compliance posture forbids any workload server from having a directly attached public IP, no exceptions.
- The engineering timeline for the exception work exceeds what the business will accept.

**Effort:** Higher than Option A. It combines the standard server migration work with the engineering work to put the exception in place, which is a separate, reviewed change.

### Option C — Leave CTI v7 in the current AWS account

Do not migrate CTI v7 at all. Move WS Aheeva, the two web apps, and the database as planned. The migrated WS Aheeva reaches CTI v7 in its current location across the public internet, using CTI v7's existing public IP.

**What changes compared to today:**

- The three other servers and the database move to the new environment as planned.
- WS Aheeva now reaches CTI v7 from the new environment, connecting to CTI v7's existing public IP. CTI v7's current security group has to allow the new environment's outbound public IP on whatever port WS Aheeva uses.
- Everything about CTI v7's SIP configuration and network shape stays exactly as it is today.
- The current AWS account has to stay alive indefinitely to host CTI v7. It is not fully decommissioned.

**What stays the same:**

- CTI v7 keeps its current public IP, current SIP configuration, and current security rules.
- SIP peers and voice partners see no change on CTI v7 itself.

**Risks and constraints:**

- **The current AWS account remains a running system.** You continue to pay the baseline account costs (guardrails, logging, monitoring) for as long as CTI v7 lives there. This is not a large monthly figure, but it is not zero.
- **Your operations story is split across two AWS accounts.** Debugging, monitoring, patching, and access control for CTI v7 remain in the old-tenant world. Runbooks have to note which account each service is in.
- **CTI v7 stays on the legacy security posture unless you invest in hardening it in place.** The current security group has 18 public IPs allowlisted directly on the database. That has grown organically over years. This migration is the natural time to clean up, but for CTI v7 that cleanup would need to happen in place rather than as part of moving. If we choose Option C, this hardening work has to actually happen; otherwise CTI v7 remains permanently exposed in ways the other migrated servers are not.
- **Traffic between the migrated WS Aheeva and CTI v7 goes over the public internet.** Functionally fine, latency is negligible (single-digit milliseconds between the two AWS regions), but the trust boundary changes: what would have been an internal call is now an external one, and the logs and monitoring reflect that.
- **If CTI v7 ever opens a direct connection to `iccmaindb`**, Option C requires either keeping the database publicly reachable in the new environment (which undoes one of the main security wins of the migration) or building an inter-account network path between the two AWS accounts. Both are significant additions that make Option C much less attractive. This is why question 6 above matters.

**If Option C is chosen, the following hardening work should happen in the current AWS account:**

- Reduce the 18 public IPs currently allowlisted on the database security group down to only what is genuinely required.
- Restrict CTI v7's own security group to the exact set of sources it needs (SIP peers, WS Aheeva's outbound IP, admin access).
- Enable AWS Systems Manager Session Manager on CTI v7 so administrators no longer connect over SSH from the public internet.
- Enable CloudTrail data events, VPC flow logs, and GuardDuty in the account if they are not already on.
- Rotate any long-lived IAM access keys and prefer federated access.
- Establish a monthly application-consistent AMI backup with a rolling three-month retention, as a disaster-recovery baseline.

**When Option C fits:**

- CTI v7 does not open direct MySQL connections to the database.
- Inbound SIP with a direct public IP is a hard requirement and Option B is not palatable.
- You are comfortable keeping two AWS accounts operational long-term.

**When Option C does not fit:**

- The migration's goal is to fully decommission the current AWS account.
- CTI v7 opens direct connections to the database.

**Effort:** Lowest effort in the new environment, highest ongoing operational cost, because the old account stays live.

## Comparison at a glance

| | Option A: Private server in new env | Option B: Scoped exception in new env | Option C: Leave in current env |
|---|---|---|---|
| CTI v7 has a directly attached public IP | No | Yes | Yes (unchanged) |
| Handles inbound SIP calls | No | Yes | Yes (unchanged) |
| Direct RTP media | No | Yes | Yes (unchanged) |
| Current AWS account fully retired | Yes | Yes | No |
| Guardrail changes required in new env | None | Multiple coordinated changes | None |
| Ongoing multi-account operational overhead | No | No | Yes |
| Reversibility | Low (re-migrate) | Medium (remove exception) | Medium (migrate later) |
| SIP cutover risk | Low (if no SIP), High (if SIP present) | Low (network shape identical to today) | None (nothing moves for CTI v7) |
| Path between WS Aheeva and CTI v7 | Internal network | Internal network | Public internet |

## Our recommendation

Our default preference, ordered by fit:

1. **If CTI v7 does not handle SIP → Option A.** The reasons to consider B or C only exist because of SIP. Without SIP, this is a routine server migration.
2. **If CTI v7 handles SIP only in the outbound direction, and the carrier tolerates a source-IP change → Option A.** Adding or reusing a session border controller in front is a viable alternative if the carrier is inflexible.
3. **If CTI v7 handles inbound SIP or direct RTP → Option B.** Accept the scoped exception in exchange for a network shape that SIP is known to survive. Modeled on a similar exception pattern we are already familiar with.
4. **Option C if Option B is blocked on compliance or timeline grounds, and CTI v7 does not talk to the database directly.** It works, but the operational tax of keeping two AWS accounts long-term is real and should be factored into your total-cost-of-ownership.

We would advise against trying to make Option A work for a real inbound-SIP or direct-RTP workload by stitching together additional load balancers and traffic accelerators. There are protocols where that approach works well. SIP with direct RTP is not one of them, and in our experience deployments that go down this path end up either adding a session border controller anyway or migrating to Option B a few months later.

## Decision checklist

For your team, in order:

1. Does CTI v7 handle SIP traffic? If **no**, choose Option A.
2. Is SIP inbound to CTI v7 or only outbound? If **outbound only**, and the carrier tolerates a new source IP, choose Option A.
3. Does RTP media terminate directly on CTI v7, or is there a session border controller in between? If **an SBC exists**, choose Option A.
4. Is your team willing to authorize the guardrail exception work in the new environment for one specifically tagged server? If **yes**, choose Option B. If **no**, choose Option C.
5. Is fully retiring the current AWS account a hard requirement? If **yes**, Option C is off the table.
6. Does CTI v7 open direct MySQL connections to the database? If **yes**, Option C is off the table.

## Next steps regardless of option

- We need answers to the six questions in the "Questions we need answered" section above.
- If SIP is in play, we would appreciate a copy of the SIP configuration file on CTI v7 (`sip.conf` or `pjsip.conf`, depending on the SIP stack in use). Specifically, we care about the `externip`, `nat`, `localnet`, and the RTP port range values. These determine whether Option A can survive with configuration tweaks or genuinely cannot.
- Basic CTI v7 inventory: current instance type, disk size, current public IP, current security group rules. This applies to all three options.

We are happy to walk through this document with your team on a call — decision items 4 through 6 in particular tend to be easier in a live conversation than in writing.
