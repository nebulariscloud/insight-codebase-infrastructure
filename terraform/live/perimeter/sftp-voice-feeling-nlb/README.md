# SFTP VOFeeling NLB (Perimeter)

Internet-facing Network Load Balancer in the perimeter ingress VPC that fronts
the SFTP VOFeeling server in
[`terraform/live/production/sftp-voice-feeling/`](../../production/sftp-voice-feeling/).
Same shape as the existing [`sftp-nlb`](../sftp-nlb/) leaf.

## Why an NLB and not the ALB

ALBs are HTTP/HTTPS only. SFTP is raw TCP on port 22, which terminates at L4.
NLBs forward L4 traffic transparently; ALBs cannot. That's why this is an NLB
and there is no ACM cert / WAF here.

## Static IPs

The NLB does NOT allocate EIPs (`lza-infrastructure-guardrails-1` SCP denies
`ec2:AllocateAddress` for non-LZA principals). It uses the AWS-managed public
IP per AZ, which is stable for the life of the NLB and only changes on
destroy/recreate. `deletion_protection = true` keeps that from happening in
normal operation.

## Architecture

```
SFTP partner (Five9 / VICIDIAL / PEI-BG / CLARA / ZIMA)
  │  TCP/22
  ▼
[ NLB (Perimeter ingress) ]   ← AWS-managed public IPs (one per AZ)
  │  TCP/22 (SNAT, preserve_client_ip=false)
  ▼  via TGW
[ SFTP VOFeeling server (shared-prod, Production account, 10.12.1.62) ]
```

## Allowlist

`allowed_source_cidrs` is pre-populated with the partner IPs carried over from
the source `F9_SFTP_SG`. The legacy `0-65535` rule from `67.219.151.138/32`
(VICIDIAL AST1) was **not** reproduced — the NLB forwards only `:22`. If that
host genuinely needs more than SFTP, add the extra port(s) explicitly rather
than reopening the full range.

Because `preserve_client_ip = false`, the SFTP server only ever sees NLB
private IPs, so this NLB SG is the single IP-allowlist enforcement point.

## Apply order (one-time)

Applied by CI on merge. The order matters:

1. The EC2 leaf (`../../production/sftp-voice-feeling/`) first — it prints
   `private_ip`.
2. `sftp_server_private_ip` here is pre-pinned to `10.12.1.62` to match the
   EC2 leaf's pinned IP, so no hand-off edit is needed unless that changes.
3. This NLB leaf second.

## Verifying

```bash
NLB_DNS=$(terraform output -raw nlb_dns_name)
nc -zv "$NLB_DNS" 22 -w 5
# expected: Connection to <NLB_DNS> 22 port [tcp/ssh] succeeded!
```

If `nc` succeeds but `sftp` fails, the migrated sshd may be bound to the old
private IP via `ListenAddress` in `/etc/ssh/sshd_config` — reset it to
`0.0.0.0` and restart sshd.

## Allowlist hand-off

```bash
terraform output -json nlb_public_ips
```

Send the partner both AZ IPs (and `nlb_dns_name` if their tooling accepts a
hostname). Both need allowlisting because DNS round-robins between them.

## See also

- `terraform/live/production/sftp-voice-feeling/` — the SFTP server this fronts
- `terraform/live/perimeter/sftp-nlb/` — the reference NLB leaf
