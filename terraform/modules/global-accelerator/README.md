# Module: global-accelerator

Global Accelerator in front of an ALB. Same shape as the existing `scriptcase-ga.yaml` stack.

## Important: provider region

Global Accelerator's control plane only lives in **us-west-2**. The ALB can be anywhere — the accelerator is global and routes to it. Configure the leaf's provider to `us-west-2`:

```hcl
provider "aws" {
  region = "us-west-2"
  assume_role { role_arn = "..." }
}
```

## Usage

```hcl
data "aws_ssm_parameter" "alb_arn" {
  # Or pull from terraform_remote_state if you'd rather wire stacks together
  name = "/apps/scriptcase/alb-arn"
}

module "ga" {
  source = "../../../modules/global-accelerator"

  name       = "scriptcase-ga"
  alb_arn    = data.aws_ssm_parameter.alb_arn.value
  alb_region = "us-east-2"
}

# After apply, share these with the vendor:
output "static_ips" {
  value = module.ga.accelerator_static_ips
}
```
