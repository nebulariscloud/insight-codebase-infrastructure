###############################################################################
# Discovery (CloudShell, signed in to Perimeter / us-east-2):
#
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*ingress*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
#     "Name=tag:Name,Values=*public*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
#
# Or copy the values from the existing sftp-nlb / wazuh-nlb leaf - same
# VPC and same public subnets.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "sftp-claro-nlb"
region       = "us-east-2"

# Same as sftp-nlb / wazuh-nlb tfvars - perimeter ingress VPC + public subnets.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Read from the production/sftp-server-claro leaf:
#   cd ../../production/sftp-server-claro && terraform output -raw private_ip
sftp_server_private_ip = "10.12.1.51"

sftp_port = 22

# Tighten to Claro's egress CIDRs once known. Default 0.0.0.0/0.
# allowed_source_cidrs = ["203.0.113.0/24"]
