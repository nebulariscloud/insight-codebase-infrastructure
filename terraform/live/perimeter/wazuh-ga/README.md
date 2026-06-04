# Wazuh Global Accelerator (Perimeter)

Puts AWS Global Accelerator in front of the Wazuh ingress, exposing two
static anycast IPv4 addresses for vendor allowlists and partner
integrations that need stable IPs.

The same accelerator now serves all five Wazuh ports:

```
clients
   │  80 / 443 / 1514 / 1515 (TCP) + 514 (UDP)
   ▼
wazuh-ga (this stack, 2 static anycast IPs)
 ├── :80, :443 (TCP)   ──► ingress-alb (LZA-managed, HTTPS, WAF, dashboard/API)
 ├── :1514, :1515 TCP  ──► wazuh-nlb (sibling stack, agent events / enrollment)
 └── :514 UDP          ──► wazuh-nlb (sibling stack, syslog input)
```

## What this owns

- One Global Accelerator
- Listener for ALB traffic (TCP/80, TCP/443) + endpoint group → `ingress-alb`
- Listener for agent traffic (TCP/1514–1515) + endpoint group → `wazuh-nlb`
- Listener for syslog traffic (UDP/514) + endpoint group → `wazuh-nlb`

The 80/443 path goes through the module (`modules/global-accelerator`) the
same way ScriptcaseGA does. The 1514–1515 and UDP/514 paths use raw GA
resources in this leaf because the module is shaped for a single
listener+endpoint pair; reshaping it to support N pairs would be more
complexity than just adding the extra resources here. The syslog listener
is its own resource (not folded into the agent listener) because GA
listeners are single-protocol — TCP and UDP cannot share one.

## What this does NOT own

- `ingress-alb` (LZA owns it via `custom-stacks/ingress-alb.yaml`)
- `wazuh-nlb` (sibling Terraform leaf at `terraform/live/perimeter/wazuh-nlb`)
- The Wazuh EC2 instance (in shared-prod / Production, not Perimeter)
- DNS records pointing at the GA. Add those in a Route53 leaf later if you
  want a friendly DNS name

## Why two providers

- Default provider: `us-west-2` — Global Accelerator's control plane only
  lives there. The accelerator is global; this is just where AWS keeps the
  control plane API.
- `aws.alb_region`: `us-east-2` — for the `data "aws_lb"` lookups of the
  ALB and NLB, both of which live in `us-east-2`.

Both providers assume the same `TerraformExecution` role in Perimeter
(`713939170920`); only the region differs.

## After apply

```bash
cd terraform/live/perimeter/wazuh-ga
terraform output accelerator_static_ips
```

The two static IPs are unchanged from the previous apply — adding the
1514–1515 listener and the UDP 514 listener does not change the
accelerator's IP allocation.

## Verifying agent ports work end-to-end

From any host with internet access:

```bash
GA_IP=<one of accelerator_static_ips>
nc -zv $GA_IP 1514 -w 5
nc -zv $GA_IP 1515 -w 5
curl -kI https://$GA_IP/

# UDP syslog: nc -u doesn't really confirm reachability (UDP has no
# handshake), so send a real frame and verify on the manager.
logger -n $GA_IP -P 514 -d "test from $(hostname)"
# On the Wazuh manager:
#   sudo tail -f /var/ossec/logs/archives/archives.log | grep "test from"
```

`succeeded` on 1514 / 1515 means GA → NLB → manager is healthy. If `nc`
times out, the most likely cause is the Wazuh manager security group not
yet allowing 1514/1515 inbound (since `preserve_client_ip = true` all the
way through, the SG must allow `0.0.0.0/0` on those ports).

For UDP 514, if the syslog frame never appears in `archives.log`, check
in this order: GA listener exists (UDP/514), NLB UDP target group is
healthy, manager SG allows UDP 514 inbound from the world (preserve
client IP is on), and the Wazuh manager has a syslog `<remote>` block
configured in `/var/ossec/etc/ossec.conf`. The most common cause of
"no logs arriving" is the last one — GA + NLB will deliver the packet,
but if `ossec.conf` isn't configured to listen on UDP 514 the manager
drops it silently.

## Cost

- Global Accelerator: ~$18/month flat per accelerator + $0.025/GB out
  (data transfer is the lever; the flat fee is small)
- Adding the second listener does **not** create a new accelerator — same
  flat fee, slightly more data transfer charges proportional to agent
  traffic
- No additional WAF / ALB / NLB charges — those are already paid by their
  respective stacks
