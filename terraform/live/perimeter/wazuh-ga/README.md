# Wazuh Global Accelerator (Perimeter)

Puts AWS Global Accelerator in front of the Wazuh ingress, exposing two
static anycast IPv4 addresses for vendor allowlists and partner
integrations that need stable IPs.

The same accelerator now serves all four Wazuh ports:

```
clients
   │  80 / 443 / 1514 / 1515
   ▼
wazuh-ga (this stack, 2 static anycast IPs)
 ├── :80, :443        ──► ingress-alb (LZA-managed, HTTPS, WAF, dashboard/API)
 └── :1514, :1515     ──► wazuh-nlb (sibling stack, raw TCP to the manager)
```

## What this owns

- One Global Accelerator
- Listener for ALB traffic (TCP/80, TCP/443) + endpoint group → `ingress-alb`
- Listener for agent traffic (TCP/1514–1515) + endpoint group → `wazuh-nlb`

The 80/443 path goes through the module (`modules/global-accelerator`) the
same way ScriptcaseGA does. The 1514–1515 path uses raw GA resources in
this leaf because the module is shaped for a single listener+endpoint
pair; reshaping it to support N pairs would be more complexity than just
adding the two extra resources here.

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
1514–1515 listener does not change the accelerator's IP allocation.

## Verifying agent ports work end-to-end

From any host with internet access:

```bash
GA_IP=<one of accelerator_static_ips>
nc -zv $GA_IP 1514 -w 5
nc -zv $GA_IP 1515 -w 5
curl -kI https://$GA_IP/
```

`succeeded` on 1514 / 1515 means GA → NLB → manager is healthy. If `nc`
times out, the most likely cause is the Wazuh manager security group not
yet allowing 1514/1515 inbound (since `preserve_client_ip = true` all the
way through, the SG must allow `0.0.0.0/0` on those ports).

## Cost

- Global Accelerator: ~$18/month flat per accelerator + $0.025/GB out
  (data transfer is the lever; the flat fee is small)
- Adding the second listener does **not** create a new accelerator — same
  flat fee, slightly more data transfer charges proportional to agent
  traffic
- No additional WAF / ALB / NLB charges — those are already paid by their
  respective stacks
