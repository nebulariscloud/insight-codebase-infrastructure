# NLB module

Thin Terraform module: Network Load Balancer + one Elastic IP per subnet.

## Why thin

Every NLB in this repo tends to have a bespoke listener mix (some forward to
an ALB target, some to raw EC2 IPs on different ports). Packing that into
module variables hides too much. The module owns the LB and its EIPs;
listeners and target groups stay in the leaf root where they're easy to read.

## What it owns

- `aws_lb` (NLB)
- `aws_eip` per subnet (when `allocate_eips = true`, the default)

## What the caller still creates

- `aws_lb_listener` per port
- `aws_lb_target_group` per backend
- `aws_lb_target_group_attachment` for instance/IP targets
- Any inbound rules on backend security groups to allow the NLB

## Typical usage

```hcl
module "nlb" {
  source = "../../../modules/nlb"

  name       = "wazuh-nlb"
  vpc_id     = data.aws_ssm_parameter.ingress_vpc_id.value
  subnet_ids = [
    data.aws_ssm_parameter.public_a.value,
    data.aws_ssm_parameter.public_b.value,
  ]
}

# 443 -> ALB target (NLB-in-front-of-ALB pattern, keeps WAF on the ALB)
resource "aws_lb_target_group" "to_alb" {
  name        = "wazuh-nlb-to-alb"
  target_type = "alb"
  port        = 443
  protocol    = "TCP"
  vpc_id      = data.aws_ssm_parameter.ingress_vpc_id.value
}

resource "aws_lb_target_group_attachment" "to_alb" {
  target_group_arn = aws_lb_target_group.to_alb.arn
  target_id        = data.aws_lb.ingress_alb.arn
  port             = 443
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.to_alb.arn
  }
}
```

## Notes

- `target_type = "alb"` requires NLB and ALB to be in the same VPC.
- `target_type = "ip"` supports cross-VPC targets (via TGW). Useful for
  hub-and-spoke topologies where the LB is in the perimeter VPC and the
  workload is in a spoke.
- Cross-zone LB is OFF by default. NLB cross-zone is billed (per-GB data
  transfer); ALB's is free. Only enable if you need single-AZ resilience
  for targets.
