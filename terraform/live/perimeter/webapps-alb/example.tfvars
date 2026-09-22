###############################################################################
# Discovery (CloudShell, signed in to Perimeter / us-east-2):
#
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*ingress*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
# Or copy the ingress_vpc_id / public_subnet_ids from the crm-alb leaf - same
# VPC and subnets.
#
# Backend IPs come from the two production webapp leaves:
#   cd ../../production/webapps       && terraform output -raw private_ip
#   cd ../../production/webapps-php73 && terraform output -raw private_ip
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "webapps-alb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

webapps_private_ip       = "10.12.X.X"
webapps_php73_private_ip = "10.12.X.X"

backend_port         = 80
health_check_path    = "/healthy.txt"
health_check_matcher = "200"

# Keep false first so the cert can validate; flip once ISSUED.
enable_https = false
