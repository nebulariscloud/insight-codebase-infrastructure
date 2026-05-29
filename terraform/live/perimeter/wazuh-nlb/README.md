# Wazuh NLB (Perimeter)

Internet-facing Network Load Balancer in the Perimeter ingress VPC that
provides:

- **Static IPs** (one EIP per AZ) for customers to allowlist.
- **TCP listeners on 1514 / 1515** for Wazuh agent events and enrollment.
  The existing ALB cannot carry these (ALB is HTTP-only).
- **TCP listener on 443** that forwards to the existing LZA-managed ALB
  (`ingress-alb`), so dashboard / API traffic still flows through the WAF.

## Why this exists

The existing `wazuh-ga` (Global Accelerator) only has listeners for 80/443.
Wazuh agents on 1514/1515 silently timeout because there's no path for raw
TCP. ALBs cannot carry raw TCP, so the fix is an NLB:

```
clients
   │  443 / 1514 / 1515
   ▼
NLB (this stack, EIPs)
 ├── :443   ──► ingress-alb (LZA-managed)  ──► Wazuh dashboard / API
 ├── :1514  ──► Wazuh manager IP (TGW)     ──► raw TCP, no ALB hop
 └── :1515  ──► Wazuh manager IP (TGW)     ──► raw TCP, no ALB hop
```

The `wazuh-ga` leaf can stay alongside until consumers cut over to the NLB
EIPs. Once everyone's migrated, destroy that stack to drop the GA cost.

## What this owns

- `aws_lb` (NLB) + one `aws_eip` per public subnet
- One security group on the NLB
- Three listeners (443 → ALB target, 1514 → IP target, 1515 → IP target)
- Three target groups + attachments

## What this does NOT own

- `ingress-alb` ALB (LZA owns it via `custom-stacks/ingress-alb.yaml`)
- Wazuh manager EC2 (lives in shared-prod / Production)
- Route53 records — add a separate `dns` leaf later if you want a friendly
  hostname pointing at `module.nlb.nlb_dns_name`
- The Wazuh manager security group's inbound rules. Those still need to allow
  1514/1515 from client IPs (or from the ingress VPC CIDR if you flip
  `preserve_client_ip = false`)

## First-time setup

1. Get the inputs from CloudShell — see `example.tfvars` for the discovery
   commands.
2. Copy `example.tfvars` → `terraform.tfvars` and fill in
   `wazuh_manager_ips`. The other values are already pulled from the existing
   `IngressALB` CloudFormation parameters.
3. Run:

   ```bash
   cd terraform/live/perimeter/wazuh-nlb
   aws sso login --profile lza-tooling
   export AWS_PROFILE=lza-tooling
   terraform init
   terraform plan -out tfplan
   terraform apply tfplan
   ```

4. Grab the static IPs:

   ```bash
   terraform output static_ips
   ```

   Share those with whoever runs the agents.

## Verifying it works

From any host that can reach the internet (or CloudShell):

```bash
# Replace with one of the EIPs from `terraform output static_ips`
NLB_IP=<eip>

# 443 - should hit the ALB and respond (200/302/401 depending on path)
curl -kI https://$NLB_IP/

# 1514 / 1515 - raw TCP. nc is the right tool here, not curl.
nc -zv $NLB_IP 1514 -w 5
nc -zv $NLB_IP 1515 -w 5
```

`nc` should print `succeeded`. If it says `Connection refused`, the NLB is
reachable but the Wazuh manager isn't listening. If it says `timed out`,
either the NLB SG, the manager SG, or the TGW route is dropping traffic.

## Wazuh manager SG checklist

The manager EC2 (in shared-prod) needs an SG rule:

- Inbound TCP 1514 from `0.0.0.0/0` (because `preserve_client_ip = true`)
- Inbound TCP 1515 from `0.0.0.0/0` (same reason)

If you'd rather keep the manager SG tight, set
`preserve_client_ip = false` on the two IP target groups in `main.tf`. Then
the manager only needs to allow the Perimeter ingress VPC CIDR — but you
lose real client IPs in the Wazuh logs.

## Cost

- NLB: ~$16/month + ~$0.006 per LCU-hour
- Two EIPs attached to the NLB: free (EIPs are only billed when unattached)
- No additional GA / WAF / ALB costs - the NLB rides on top of what's already
  there

## Cutover from Global Accelerator

The existing `wazuh-ga` stack continues to work (for 80/443). Migration:

1. Apply this stack. Pull the NLB EIPs.
2. Update DNS / customer allowlists to point at the NLB EIPs instead of the
   GA anycast IPs.
3. Once traffic confirms moved (CloudWatch -> ALB / NLB request count),
   `terraform destroy` the `wazuh-ga` leaf to stop the ~$18/month GA fee.
