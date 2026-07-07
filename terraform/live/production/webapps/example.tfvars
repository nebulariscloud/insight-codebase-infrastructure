###############################################################################
# Copy to terraform.tfvars and fill in.
#
# Discovery (CloudShell, Production / us-east-2):
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*shared-prod*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
#     "Name=tag:Name,Values=*shared-prod-app*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "webapps"
region       = "us-east-2"

name          = "webapps"
instance_type = "t3.small"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# private_ip = "10.12.1.60"

root_volume_size_gib = 45
app_ports            = [80, 443]
ingress_vpc_cidr     = "10.0.0.0/20"

# eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
