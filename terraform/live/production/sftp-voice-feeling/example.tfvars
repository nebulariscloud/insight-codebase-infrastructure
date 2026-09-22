###############################################################################
# Copy to terraform.tfvars and fill in.
#
# Discovery (CloudShell, signed in to Production / us-east-2):
#
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*shared-prod*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
#     "Name=tag:Name,Values=*shared-prod-app*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "sftp-voice-feeling"
region       = "us-east-2"

name          = "sftp-voice-feeling"
instance_type = "t3.micro"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# Pin the private IP so the NLB target stays stable across instance rebuilds.
# private_ip = "10.12.1.62"

# Match the AMI's root snapshot size (visible in BlockDeviceMappings.Ebs.VolumeSize)
root_volume_size_gib = 80

# Default 22. Change only if sshd_config listens on a different port.
sftp_port = 22

ingress_vpc_cidr = "10.0.0.0/20"

# Optional. EC2 Instance Connect Endpoint SG in shared-prod for admin SSH.
# eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
