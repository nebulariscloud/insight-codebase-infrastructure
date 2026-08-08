###############################################################################
# Copy to terraform.tfvars and fill in.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "ws-aheeva-ftps"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

ws_aheeva_private_ip = "10.12.1.66"

ftps_control_port = 990
ftps_passive_from = 40000
ftps_passive_to   = 40019

# allowed_source_cidrs = ["203.0.113.0/24"]
