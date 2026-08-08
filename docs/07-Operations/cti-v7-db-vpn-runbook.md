# CTI v7 reporting-DB — Site-to-Site VPN runbook

Bringing on-prem client sites onto the private `iccmaindb` (and the separate reporting
MySQL box) over IPsec Site-to-Site VPN into the LZA-managed Transit Gateway.

- **Owner:** Alex
- **Delivery:** LZA config zip → accelerator pipeline (this is a network-fabric change, **not** a Terraform leaf, **not** a local apply).
- **LZA version:** v1.14.1 (Universal Config v1.1.0)
- **TGW:** `{{AcceleratorPrefix}}-{{HomeRegion}}-tgw` (Network account), route table `tgw-rt-spoke` (shared-prod is associated here).
- **Config file touched:** `aws-accelerator-config/network-config.yaml` — `customerGateways` block + static routes in `tgw-rt-spoke`.

---

## Site status

All four sites confirmed. Scope = these 3 Insight sites + the Liberty datacenter.
("Col" in earlier WhatsApp threads = Colombia = **Zima**, not a separate site.)

| Site | Location | FortiGate | Peer (VPN endpoint) IP | Routed CIDRs |
|---|---|---|---|---|
| **Liberty – Worldnet** | Liberty DC | — | `23.249.138.106` | `172.16.10.0/24` |
| **Insight Kennedy – Worldnet** | Puerto Rico HQ | 100F | `64.89.2.105` | `172.27.150.0/27`, `172.27.100.0/24`, `172.27.50.0/25`, `172.27.75.0/24`, `172.27.200.0/24`, `172.27.220.0/24`, `172.26.4.0/22`, `192.168.100.0/24`, `192.168.20.128/29`, `192.168.70.0/26`, **`100.64.4.0/22`** (NAT) |
| **Insight RD – Altice** | Republica Dominicana | 100E | `190.166.239.186` | `172.20.0.0/24`, `172.20.1.0/24`, `172.20.2.0/24`, `172.20.3.0/24`, `172.20.4.0/24`, **`100.64.0.0/22`** (NAT) |
| **Insight Zima – Tigo** | Colombia | 120G | `181.207.82.178` | **`100.64.8.0/22`** (NAT — its only route) |

Routing is **static** on the AWS side for all sites (they run OSPF internally;
irrelevant to AWS, no BGP ASN provided). All FortiGates run **FortiOS 6.4.4+**.

### The 10.234.x overlap and the source-NAT fix

LZA's `GlobalCidr` is `10.0.0.0/8`, and the TGW owns that entire space. Any on-prem
LAN inside `10.234.x` is unreachable over VPN — AWS treats it as its own internal
address and never sends it down the tunnel.

Resolved: each site **source-NATs** its `10.234.x` LANs on the FortiGate into a
dedicated CGNAT (`100.64.0.0/10`) range, one per site. We route the NAT range and
never the `10.234.x` prefix. One range per site (not per LAN segment) — traffic is
unidirectional (sites initiate to the DB), so PAT behind a single range is
sufficient, and distinct per-site ranges preserve attribution in SG rules and logs.

| Site | LANs source-NAT'd | Arrives at AWS as |
|---|---|---|
| Insight RD | `10.234.3.0/24`, `10.234.4.0/24` | `100.64.0.0/22` |
| Insight Kennedy | `10.234.5.0/26` | `100.64.4.0/22` |
| Insight Zima | all 11 `10.234.x` subnets | `100.64.8.0/22` |

Ranges verified non-overlapping with each other, outside `10.0.0.0/8`, and clear of
the natively-routed `172.x` / `192.168.x`.

For Kennedy and RD the NAT applies **only** to those specific subnets — the rest of
their networks pass natively. For Zima the NAT applies to everything, since all of
its LANs are `10.234.x`.

### Phase-2 selectors

The selectors on each FortiGate must match the routed CIDR list above **exactly**.
A broader selector negotiates fine but silently drops traffic for anything without a
matching TGW static route. The remote/destination side is always the shared-prod VPC:
**`10.12.0.0/16`** (verified via `describe-vpcs` on `vpc-04a8720d0ddb40713`).

---

## Steps to create the first three tunnels

### 1. Confirm peer IPs
Get the one-line "yes these are the FortiGate VPN endpoints" from the provider for
Liberty / Kennedy / RD. Update `network-config.yaml` if any differ from what's staged.

### 2. Sanity-check the config
The `customerGateways` block + `tgw-rt-spoke` static routes are already in
`aws-accelerator-config/network-config.yaml`. In-file TODOs to resolve:
- `ipAddress` per site = confirmed VPN endpoint.
- `asn: 65000` — placeholder; with `staticRoutesOnly: true` it's not used for routing, but the field is required.
- Decide: let LZA **auto-generate** tunnel inside-CIDRs + pre-shared keys (recommended), or pin them via `vpnConnections[].tunnelSpecifications`.

### 3. Ship via the accelerator pipeline
Zip `aws-accelerator-config/` and upload/commit per the normal LZA config flow, then
run the pipeline. It creates, in the Network account:
- 3 customer gateways (Liberty, Kennedy, RD)
- 3 VPN connections (2 tunnels each) attached to the TGW
- the TGW VPN attachment + static routes in `tgw-rt-spoke`

### 4. Hand each site its FortiGate config
Once the VPN connections exist, download the vendor config AWS generates for each and
send it to the provider so they configure their end:

```
aws ec2 get-vpn-connection-device-sample-configuration \
  --vpn-connection-id <vpn-id> \
  --vpn-connection-device-type-id <fortinet-type-id> \
  --region <HomeRegion>
```

(Find the Fortinet `--vpn-connection-device-type-id` via
`aws ec2 get-vpn-connection-device-types`.) The provider applies this on each
FortiGate; tunnels come up once both ends match.

### 5. Allow the DB + verify
- Add SG ingress on `3306` for each site's routable CIDRs (the Terraform DB leaf's SG, or the reporting-MySQL SG — whichever the site is a client of).
- Confirm tunnel status **UP** (both tunnels ideally) in the VPN console / `describe-vpn-connections`.
- Test a DB connection from one host per site.

---

## What to tell the provider now

Three sites (Liberty, Kennedy, Insight RD) are ready — we just need the peer-IP
confirmation to bring their tunnels up. Insight Zima and a few individual subnets at
Kennedy/RD are on hold because they use `10.234.x`, which collides with our internal
AWS addressing; those need source-NAT on the FortiGate before they can connect.

See the ready-to-send bilingual message alongside this runbook.

---

## See also

- `.kiro/journal/2026-06-26-aheeva-cluster-migration-plan.md` — full working record.
- `aws-accelerator-config/network-config.yaml` — the `customerGateways` block + `tgw-rt-spoke` routes.
- `cti-v7-cluster-migration-plan.md` — the broader cluster migration.
