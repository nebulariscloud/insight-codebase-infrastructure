###############################################################################
# Copy to terraform.tfvars and fill in.
#
# Discovery (CloudShell in Production / us-east-2):
#
#   aws ec2 describe-vpcs --region us-east-2 \
#     --filters "Name=tag:Name,Values=*shared-prod*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   aws ec2 describe-subnets --region us-east-2 \
#     --filters "Name=vpc-id,Values=<vpc>" \
#               "Name=tag:Name,Values=*shared-prod-app*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
#
#   aws ec2 describe-network-interfaces --region us-east-2 \
#     --filters "Name=subnet-id,Values=<subnet>" \
#     --query 'NetworkInterfaces[].[PrivateIpAddress,Description]' --output table
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "insight-ubuntu-prod"
region       = "us-east-2"

name          = "insight-ubuntu-prod"
instance_type = "t3.medium"

vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

private_ip = "10.12.1.XX"

root_volume_size_gib = 30

eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
