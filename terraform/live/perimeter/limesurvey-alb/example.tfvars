###############################################################################
# Copy to terraform.tfvars. Same ingress VPC + subnets as osticket-alb / crm-alb.
# backend_private_ip comes from terraform/live/production/icc-limesurvey.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "limesurvey-alb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

backend_private_ip = "10.12.1.83"
backend_port       = 80

health_check_path    = "/"
health_check_matcher = "200,301,302"

enable_https = false

# allowed_source_cidrs: defaults to the partner allowlist in variables.tf.
# allowed_source_cidrs = ["203.0.113.0/24"]
