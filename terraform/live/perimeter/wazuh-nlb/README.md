# Wazuh NLB (Perimeter)

Internet-facing Network Load Balancer in the Perimeter ingress VPC that
provides:

- **TCP listeners on 1514 / 1515** for Wazuh agent events and enrollment.
  The existing ALB cannot carry these because ALBs are HTTP-only.
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
   │  443 / 1514 / 1515
   ▼
wazuh-ga  (Global Accelerator, 2 static anycast IPs - sibling stack)
 ├── :443   ──► ingress-alb (LZA-managed, HTTPS, WAF)
 └── :1514  ──► wazuh-nlb (this stack)
 └── :1515  ──► wazuh-nlb (this stack)
                      │
                      ├── :443   ──► ingress-alb target  (HTTPS, WAF)
                      ├── :1514  ──► Wazuh manager IP   (raw TCP, TGW)
                      └── :1515  ──► Wazuh manager IP   (raw TCP, TGW)
```

The `:443` listener on the NLB exists so the GA->NLB->ALB path works for
HTTPS too (single accelerator listener forwarding all three ports). It
overlaps with the GA's existing ALB endpoint group on 443 - keep whichever
is simpler once it's stable.

## What this owns

- `aws_lb` (NLB, no EIPs)
- One security group on the NLB
- Three listeners (443 → ALB target, 1514 → IP target, 1515 → IP target)
- Three target groups + attachments

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
```

If `nc` says `succeeded`, the NLB and TGW path are good. `Connection
refused` means the manager isn't listening. `timed out` means the manager
SG is blocking the traffic.

## Wazuh manager SG checklist

The manager EC2 (in shared-prod) needs an SG rule allowing 1514/1515
inbound. Because `preserve_client_ip = true` on the IP target groups, the
source IPs the manager sees will be the real agent IPs, not the NLB.

- TCP 1514 from `0.0.0.0/0`
- TCP 1515 from `0.0.0.0/0`

If you'd rather keep the manager SG tight, set
`preserve_client_ip = "false"` on the two IP target groups in `main.tf`
and re-apply, then the manager only needs the Perimeter ingress VPC CIDR
(but you lose real client IPs in Wazuh's logs).

## Cost

- NLB: ~$16/month + ~$0.006 per LCU-hour
- No EIPs (SCP-blocked)
- No additional GA / WAF / ALB costs - the NLB rides on top of what's
  already there
