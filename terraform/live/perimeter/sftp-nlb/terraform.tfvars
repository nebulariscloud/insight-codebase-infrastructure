###############################################################################
# Same VPC and public subnets as the existing wazuh-nlb leaf.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "sftp-nlb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Pinned in the production/sftp-server leaf as 10.12.1.50.
sftp_server_private_ip = "10.12.1.50"

sftp_port = 22

# Default open until partner egress is known. Tighten ASAP.
# allowed_source_cidrs = ["203.0.113.0/24"]
