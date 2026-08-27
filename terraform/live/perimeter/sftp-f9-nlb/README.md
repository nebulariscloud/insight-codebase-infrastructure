# SFTP NLB - F9 (Perimeter)

Internet-facing Network Load Balancer in the perimeter ingress VPC that
fronts the F9 SFTP server in
[`terraform/live/production/sftp-server-f9/`](../../production/sftp-server-f9/).
Same shape as the existing `sftp-nlb`, `sftp-claro-nlb` and `wazuh-nlb`
leaves.

## Why an NLB and not the existing ALB

ALBs are HTTP/HTTPS only. SFTP is raw TCP on port 22, which terminates at
L4. NLBs forward L4 traffic transparently; ALBs cannot.

## Static IPs

The NLB does NOT allocate EIPs. The infrastructure-OU SCP
(`lza-infrastructure-guardrails-1`) denies `ec2:AllocateAddress` for
non-LZA principals, so Terraform can't attach EIPs to the NLB.

The NLB gets the **AWS-managed public IP per AZ** that's assigned
automatically. These IPs are stable for the life of the NLB and only
change if the LB is destroyed and recreated. With
`deletion_protection = true` and the resources here treated as long-lived,
that's a non-event in normal operation.

If you ever need IPs that outlast NLB recreation, put a Global Accelerator
in front (sibling stack like `wazuh-ga`) - the two GA anycast IPs are
AWS-issued and never change for the life of the accelerator.

## Architecture

```
F9 SFTP partner
  │  TCP/22
  ▼
[ NLB (Perimeter ingress) ]   ← AWS-managed public IPs (one per AZ)
  │  TCP/22 (SNAT, preserve_client_ip=false)
  ▼  via TGW
[ sftp-server-f9 (shared-prod, Production account, 10.12.1.52) ]
```

## Apply order

CI applies leaves serially on merge to `main`, and this leaf's
`sftp_server_private_ip` is already pinned to the same value the EC2 leaf
pins (`10.12.1.52`), so no hand-off edit is needed between the two applies.

Order that matters: `f9-recordings` (bucket) -> `sftp-server-f9`
(instance) -> `sftp-f9-nlb` (ingress). The NLB target attachment points at
an IP, not an instance ID, so it does not hard-fail if the instance isn't up
yet - but the target will sit unhealthy until it is.

After the apply, collect the values to hand to the partner:

```bash
# From the Perimeter account
aws elbv2 describe-load-balancers --region us-east-2 \
  --names sftp-f9-nlb --query 'LoadBalancers[0].DNSName' --output text

aws ec2 describe-network-interfaces --region us-east-2 \
  --filters 'Name=description,Values=ELB net/sftp-f9-nlb/*' \
  --query 'NetworkInterfaces[].Association.PublicIp' --output json
```

## Verifying the NLB

```bash
NLB_DNS=<nlb_dns_name>

# TCP/22 reachable
nc -zv $NLB_DNS 22 -w 5
# expected: Connection to <NLB_DNS> 22 port [tcp/ssh] succeeded!

# Real handshake. Use the migrated server's host key to confirm; first
# connection will prompt to trust the fingerprint.
sftp -P 22 -i ~/.ssh/your_key user@$NLB_DNS
```

If `nc` succeeds but `sftp` fails:

- Most likely the SFTP daemon on the source-migrated server is bound to
  a specific IP that's no longer present (e.g. `ListenAddress` in
  `/etc/ssh/sshd_config` pinned to the old source-tenant address). Set it
  to `0.0.0.0` or remove the directive. Restart sshd.
- Or the server's host SG isn't allowing inbound from `10.0.0.0/20`. The
  Production `sftp-server-f9` stack opens that automatically; check it
  hasn't been overridden.

## Allowlist hand-off

Send F9 both AZ public IPs and the NLB DNS name if their tooling can use a
hostname. Both IPs need allowlisting because the NLB returns both via DNS
round-robin and clients may resolve either.

## Tightening inbound

`allowed_source_cidrs` currently defaults to `0.0.0.0/0`, matching how
`sftp-nlb` and `sftp-claro-nlb` were first stood up. **This means TCP/22 is
open to the internet until F9's egress CIDRs are supplied.** Authentication
is still required by sshd, and `preserve_client_ip = false` means the
instance SG only accepts the NLB, but the exposure is real and worth closing
early. Once you have the CIDRs, set `allowed_source_cidrs` in tfvars and
re-apply - the NLB SG rules are rebuilt, the LB itself isn't replaced.

## Cost

- NLB: ~$16/month + ~$0.006 per LCU-hour
- No EIPs (SCP-blocked)
- No additional WAF / GA costs unless you add them
