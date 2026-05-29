# Module: alb

Application Load Balancer with sane production defaults. Mirrors the shape of the existing CloudFormation `ingress-alb.yaml` so the parameter model is familiar.

## What it gives you

- ALB + security group + target group + HTTP listener (+ HTTPS if you pass a cert)
- HTTP→HTTPS redirect when a cert is set, plain HTTP forward otherwise
- Deletion protection, defensive desync mitigation, drop-invalid-headers — all on by default
- Optional access logs to an LZA-managed bucket
- Optional WAF association (build the ACL with the `waf-managed` module)
- Idempotent target registration via `target_ids`

## Usage

```hcl
module "alb" {
  source = "../../../modules/alb"

  name           = "my-app-alb"
  vpc_id         = data.aws_ssm_parameter.vpc_id.value
  subnet_ids     = [data.aws_ssm_parameter.public_a.value, data.aws_ssm_parameter.public_b.value]

  target_port     = 8080
  target_protocol = "HTTP"
  target_type     = "ip"

  health_check_path    = "/health"
  health_check_matcher = "200"

  certificate_arn = data.aws_ssm_parameter.cert_arn.value
  waf_web_acl_arn = module.waf.web_acl_arn

  tags = {
    App = "my-app"
  }
}
```

## When NOT to use this

- You need an NLB or GWLB. Build a separate module.
- The LB exists today as a CloudFormation stack (`IngressALB`, `ScriptcaseLB`). Don't re-create — `terraform import` if you ever want to move it.
