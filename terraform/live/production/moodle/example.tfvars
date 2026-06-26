###############################################################################
# Example values. Real values are in terraform.tfvars. This file documents
# the discovery commands and exists so a new operator can bootstrap from a
# blank tree.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "moodle"
region       = "us-east-2"

name          = "moodle"
instance_type = "t3a.small"

# AMI - built locally via register-image from the cross-account-copied
# Lightsail snapshot. Procedure in lightsail-migration-guide.md.
ami_id = "ami-XXXXXXXXXXXXXXXXX"

# VPC and subnet - look up with:
#   aws ec2 describe-vpcs --region us-east-2 \
#     --filters "Name=tag:Name,Values=*shared-prod*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   aws ec2 describe-subnets --region us-east-2 \
#     --filters "Name=vpc-id,Values=<vpc>" \
#               "Name=tag:Name,Values=*shared-prod-app*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# Optional. Pin so the ALB target group stays stable across replacements.
# Check existing IPs in the subnet first:
#   aws ec2 describe-network-interfaces --region us-east-2 \
#     --filters "Name=subnet-id,Values=<subnet>" \
#     --query 'NetworkInterfaces[].[PrivateIpAddress,Description]' --output table
private_ip = "10.12.1.XX"

root_volume_size_gib = 60
moodle_http_port     = 80
ingress_vpc_cidr     = "10.0.0.0/20"

# Optional. EC2 Instance Connect Endpoint SG in shared-prod. Get it with:
#   aws ec2 describe-instance-connect-endpoints --region us-east-2 \
#     --filters Name=vpc-id,Values=<shared-prod-vpc> \
#     --query 'InstanceConnectEndpoints[].SecurityGroupIds'
eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
