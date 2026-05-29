# Wazuh Global Accelerator (Perimeter)

Puts AWS Global Accelerator in front of the LZA-managed `ingress-alb` (which
fronts the Wazuh server in Production). Output: two static anycast IPv4
addresses for vendor allowlists and partner integrations that need stable IPs.

## What this owns

- One Global Accelerator
- One listener pair (TCP/80, TCP/443)
- One endpoint group in `us-east-2` pointing at the IngressALB

## What this does NOT own

- The IngressALB itself. That stays under LZA's `IngressALB` CloudFormation
  stack (`thenew-aws-accelerator-config/customizations-config.yaml`). This
  leaf reads the ALB ARN dynamically via `data "aws_lb"`.
- The Wazuh EC2 instance (in Production, not Perimeter).
- DNS records pointing at the GA. Add those in a Route53 leaf later if you
  want a friendly DNS name.

## Why two providers

- Default provider: `us-west-2` — Global Accelerator's control plane only
  lives there. The accelerator is global; this is just where AWS keeps the
  control plane API.
- `aws.alb_region`: `us-east-2` — for the `data "aws_lb"` lookup of the
  IngressALB, which lives in `us-east-2`.

Both providers assume the same `TerraformExecution` role in Perimeter
(`713939170920`); only the region differs.

## After apply

The two static IPs are in the workflow's run output and the Terraform
outputs. Pull them again later with:

```bash
cd terraform/live/perimeter/wazuh-ga
terraform output accelerator_static_ips
```

(Requires an Identity Center session into SharedServices and the leaf
already initialized.)

## Cost

- Global Accelerator: ~$18/month flat per accelerator + $0.025/GB out (data
  transfer is the lever; the flat fee is small)
- No additional WAF, ALB, or other charges - those are already paid by the
  IngressALB stack
