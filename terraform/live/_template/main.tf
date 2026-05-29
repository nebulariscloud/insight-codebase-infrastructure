###############################################################################
# Replace this file with the actual resources/modules for the stack.
#
# Example - an ALB with WAF, reading IDs from LZA-published SSM paths:
#
#   data "aws_ssm_parameter" "vpc_id"       { name = "/accelerator/network/vpc/Network-Endpoints/id" }
#   data "aws_ssm_parameter" "public_a"     { name = "/accelerator/network/vpc/Network-Endpoints/subnet/Network-Endpoints-A/id" }
#   data "aws_ssm_parameter" "public_b"     { name = "/accelerator/network/vpc/Network-Endpoints/subnet/Network-Endpoints-B/id" }
#
#   module "waf" {
#     source = "../../../modules/waf-managed"
#     name   = "${var.stack_name}-waf"
#     scope  = "REGIONAL"
#   }
#
#   module "alb" {
#     source = "../../../modules/alb"
#
#     name       = var.stack_name
#     vpc_id     = data.aws_ssm_parameter.vpc_id.value
#     subnet_ids = [data.aws_ssm_parameter.public_a.value, data.aws_ssm_parameter.public_b.value]
#
#     target_port     = 8080
#     target_protocol = "HTTP"
#     target_type     = "ip"
#
#     waf_web_acl_arn = module.waf.web_acl_arn
#   }
#
#   output "alb_dns" { value = module.alb.alb_dns_name }
###############################################################################
