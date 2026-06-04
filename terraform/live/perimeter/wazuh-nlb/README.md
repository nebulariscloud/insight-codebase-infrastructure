# Wazuh NLB (Perimeter)

Internet-facing Network Load Balancer in the Perimeter ingress VPC that
provides:

- **TCP listeners on 1514 / 1515** for Wazuh agent events and enrollment.
  The existing ALB cannot carry these because ALBs are HTTP-only.
- **UDP listener on 514** for syslog ingestion. Standard syslog (RFC 3164)
  is UDP — a TCP listener silently drops every packet. NLBs can carry
  UDP, ALBs cannot.
- **TCP listener on 443** that forwards to the existing LZA-managed ALB
  (`ingress-alb`), so dashboard / API traffic can flow over the same NLB
  while keeping the WAF in front of the ALB.

## Static IPs (important)

Originally this stack allocated EIPs on the NLB. The Infrastructure-OU SCP
(`lza-infrastructure-guardrails-1`) denies `ec2:AllocateAddress`, so EIPs
are off (`allocate_eips = false`). Instead the NLB is fronted by the
existing **`wazuh-ga`** Global Accelerator, which already exposes two
stable anycast IPs. Once `wazuh-ga` is updated to add 1514/1515 listeners
pointing at this NLB, the same two GA IPs serve everything.

## Architecture

```
clients
   │  443 / 1514 / 1515 (TCP) + 514 (UDP)
   ▼
wazuh-ga  (Global Accelerator, 2 static anycast IPs - sibling stack)
 ├── :443  TCP  ──► wazuh-nlb (this stack)
 ├── :1514 TCP  ──► wazuh-nlb (this stack)
 ├── :1515 TCP  ──► wazuh-nlb (this stack)
 └── :514  UDP  ──► wazuh-nlb (this stack)
                      │
                      ├── :443  TCP  ──► ingress-alb target  (HTTPS, WAF)
                      ├── :1514 TCP  ──► Wazuh manager IP   (raw TCP, TGW)
                      ├── :1515 TCP  ──► Wazuh manager IP   (raw TCP, TGW)
                      └── :514  UDP  ──► Wazuh manager IP   (raw UDP, TGW)
```

The `:443` listener on the NLB exists so the GA->NLB->ALB path works for
HTTPS too (single accelerator listener forwarding all three ports). It
overlaps with the GA's existing ALB endpoint group on 443 - keep whichever
is simpler once it's stable.

## What this owns

- `aws_lb` (NLB, no EIPs)
- One security group on the NLB
- Four listeners (443 TCP → ALB target, 1514 TCP → IP target, 1515 TCP →
  IP target, 514 UDP → IP target)
- Four target groups + attachments

NLB UDP target groups always preserve client IP (the option can't be
disabled), and we want it on anyway so the manager logs the real syslog
sender IP. Asymmetric-routing isn't an issue for syslog because senders
never expect a reply.

Cross-VPC IP target attachments use `availability_zone = "all"` because
the Wazuh manager (`10.12.1.121`) lives in shared-prod, reached from
Perimeter via TGW. Without this, AWS rejects target registration with
"The Availability Zone is required for IP address ... because it is not
in the VPC".

## What this does NOT own

- `ingress-alb` ALB (LZA owns it via `custom-stacks/ingress-alb.yaml`)
- Wazuh manager EC2 (lives in shared-prod / Production)
- The Wazuh manager security group (still needs inbound 1514/1515)
- The wazuh-ga accelerator and its 1514/1515 listeners (sibling stack -
  add those there in a separate commit after this stack is applied)

## First-time setup

1. Set `wazuh_manager_ips` in `terraform.tfvars`.
2. Run from your laptop (CloudShell is too disk-constrained for terraform
   init):

   ```bash
   cd terraform/live/perimeter/wazuh-nlb
   aws sso login --profile lza-tooling
   export AWS_PROFILE=lza-tooling
   terraform init
   terraform plan -out tfplan -var-file=terraform.tfvars
   terraform apply tfplan
   ```

   Or via CI: push to `main`, approve the `production` environment.

3. Output `nlb_arn` becomes the input for the `wazuh-ga` stack's
   1514/1515 listeners (next commit).

## Verifying the NLB itself

After apply, the NLB has a DNS name (`module.nlb.nlb_dns_name`). You can
test it directly to validate the LB layer before wiring up GA:

```bash
NLB_DNS=$(terraform output -raw nlb_dns_name)

# 443 -> ALB
curl -kI https://$NLB_DNS/

# 1514 / 1515 -> manager
nc -zv $NLB_DNS 1514 -w 5
nc -zv $NLB_DNS 1515 -w 5

# 514 UDP -> manager (UDP has no handshake; send a real syslog frame and
# verify on the manager's archives.log instead of relying on nc -u)
logger -n $NLB_DNS -P 514 -d "nlb-test from $(hostname)"
# On the Wazuh manager:
#   sudo tail -f /var/ossec/logs/archives/archives.log | grep nlb-test
```

If `nc` says `succeeded`, the NLB and TGW path are good. `Connection
refused` means the manager isn't listening. `timed out` means the manager
SG is blocking the traffic.

## Wazuh manager SG checklist

The manager EC2 (in shared-prod) needs an SG rule allowing 1514/1515
inbound. Because `preserve_client_ip = "false"` on the IP target groups
(see the long comment in `main.tf`), the manager only sees traffic
sourced from the NLB's private IPs in the Perimeter ingress VPC, **not**
real public agent IPs.

- TCP 1514 from the Perimeter ingress VPC CIDR (e.g. `10.0.0.0/20`)
- TCP 1515 from the Perimeter ingress VPC CIDR
- UDP 514 from `0.0.0.0/0` — NLB UDP target groups always preserve client
  IP (the option can't be disabled), so the manager will see real public
  sender IPs on syslog and the SG must allow them. Tighten to known
  customer egress IPs once they're in hand.

Why TCP runs with preserve_client_ip off: with it on, the manager's reply
to a public agent has to leave shared-prod via its default 0.0.0.0/0
route, which goes through the egress/inspection VPC instead of back
through the Perimeter ingress VPC where the NLB lives. A stateful device
on that asymmetric path RSTs the SYN-ACK after ~1ms, killing every TLS
handshake before any bytes flow. Symptom is `openssl s_client` connecting
but `write` returning ECONNRESET with 0 bytes read. Disabling
preserve_client_ip makes the NLB SNAT, so the reply path stays symmetric.
Syslog (UDP) does not have this problem because it's fire-and-forget —
no reply path to break.

Trade-off: Wazuh logs the NLB's private IPs as the TCP agent source
instead of real public IPs (UDP syslog still shows the real sender IP).
If real client IPs on the TCP path becomes a compliance requirement, the
alternative is reworking the shared-prod return-path routing so replies
to public agent IPs go back through Perimeter — fragile because public
IPs are unbounded.

In addition, the Wazuh manager must be configured to actually listen on
UDP 514. Add a `<remote>` block to `/var/ossec/etc/ossec.conf`:

```xml
<remote>
  <connection>syslog</connection>
  <port>514</port>
  <protocol>udp</protocol>
  <allowed-ips>0.0.0.0/0</allowed-ips>
</remote>
```

Restart with `sudo systemctl restart wazuh-manager`. Without this block
the manager doesn't bind UDP 514 at all and every packet GA + NLB
delivers gets dropped silently — the most common cause of "no logs
arriving".

## Cost

- NLB: ~$16/month + ~$0.006 per LCU-hour
- No EIPs (SCP-blocked)
- No additional GA / WAF / ALB costs - the NLB rides on top of what's
  already there
