###############################################################################
# Same VPC and public subnets as the existing sftp-nlb / sftp-claro-nlb /
# wazuh-nlb leaves.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "sftp-f9-nlb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Pinned in the production/sftp-server-f9 leaf as 10.12.1.52.
sftp_server_private_ip = "10.12.1.52"

sftp_port = 22

# TODO: Tighten to F9's egress CIDRs once they're provided. Default open
# until then so initial connectivity testing isn't blocked.
# allowed_source_cidrs = ["203.0.113.0/24"]
