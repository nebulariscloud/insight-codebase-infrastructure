###############################################################################
# Example values for the icc-alb leaf. Copy to terraform.tfvars and adjust.
# All values here are safe to commit (no secrets).
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "icc-alb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

backend_private_ip = "10.12.1.71"
prod_api_port      = 80
dev_api_port       = 81

prod_api_host = "crm.insightgrouppr.com"
dev_api_host  = "crm-dev.insightgrouppr.com"

health_check_path    = "/"
health_check_matcher = "200,301,302"

enable_https = false
