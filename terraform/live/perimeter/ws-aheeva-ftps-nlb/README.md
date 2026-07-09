# WS Aheeva FTPS NLB (Perimeter) — Wave 2

Internet-facing NLB that fronts **WS Aheeva** (private in shared-prod) for the
clients' daily **FTPS** file drop. Pure TCP passthrough over the perimeter <->
shared-prod TGW (same IP-target mechanism as `sftp-nlb`).

## FTPS over NLB — how it works

- **Implicit-TLS FTPS**: control on **990**, data on a **passive port range**.
- TLS terminates on **WS Aheeva itself** (the FTPS server), not the NLB. The
  NLB is pure TCP passthrough — required for FTPS, since the NLB can't rewrite
  the encrypted control channel's PASV responses.
- Each port needs its own **listener + target group** on the NLB, all pointing
  at WS Aheeva's private IP.

## ⚠️ Passive range vs NLB listener quota — READ THIS

The source FTPS server uses passive range **40000-40500 = 501 ports**. An NLB
needs **one listener per port**, and the default AWS quota is **50 listeners
per NLB**. 501 listeners will not fit (and even a quota increase makes a
sprawling, slow-to-apply stack).

**Fix: narrow the passive range** in the Aheeva FTPS server config to something
small (e.g. `40000-40019`, 20 ports — supports ~20 concurrent passive transfers)
and set `ftps_passive_from` / `ftps_passive_to` here to match. The control port
(990) plus 20 passive ports = 21 listeners, comfortably under quota.

Do this on WS Aheeva before cutover:
- vsftpd: `pasv_min_port=40000` / `pasv_max_port=40019`
- proftpd: `PassivePorts 40000 40019`
- pure-ftpd: `-p 40000:40019`
Then set the matching values in this leaf's tfvars.

## What this leaf owns

- The NLB + its SG (990 + passive range from client CIDRs).
- One target group + listener per FTPS port, all -> WS Aheeva private IP.

## Order of operations

1. Narrow the Aheeva passive range (above) and match it here.
2. Apply `production/ws-aheeva`; grab its `private_ip` -> `ws_aheeva_private_ip`.
3. Apply this leaf.
4. Read `nlb_dns_name` + `nlb_public_ips`. Give clients the DNS name; have them
   allowlist the public IPs (for their outbound), and set their FTPS target to
   the NLB endpoint.
5. Tighten `allowed_source_cidrs` to the real client source IPs.

## Notes

- `preserve_client_ip=false` (SNAT) — same return-path reasoning as `sftp-nlb`.
  WS Aheeva sees NLB private IPs, so client-IP allowlisting is enforced at the
  NLB SG (`allowed_source_cidrs`), not on the box.
- No EIPs (SCP denies AllocateAddress); the NLB's AWS-managed per-AZ IPs are
  stable for its lifetime and published via `nlb_public_ips`.
- **FTPS + SNAT caveat**: because the NLB SNATs, WS Aheeva sees all clients as
  the NLB IPs. FTPS `PASV` advertises WS Aheeva's own view of its address; make
  sure the Aheeva FTPS config advertises the NLB public IP as its passive
  address (masquerade / `pasv_address`), or passive transfers will hand clients
  an unroutable private IP. This is the FTPS analog of SIP's externip — confirm
  during cutover testing.

## See also

- `terraform/live/production/ws-aheeva/` — the backend box
- `terraform/live/perimeter/sftp-nlb/` — the sibling TCP-passthrough NLB pattern
- `cti-v7-cluster-migration-plan.md` — overall plan
