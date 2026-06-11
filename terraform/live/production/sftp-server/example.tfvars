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
stack_name   = "sftp-server"
region       = "us-east-2"

name          = "sftp-server"
instance_type = "t3.medium"
ami_id        = "ami-0142292b2f75b5156"

vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# Pin the private IP so the NLB target stays stable across instance rebuilds.
# Pick an unused address inside the chosen subnet's CIDR.
# private_ip = "10.12.1.50"

# Verify with `aws ec2 describe-images --image-ids <ami> --region us-east-2
# --query 'Images[0].BlockDeviceMappings'`. If the snapshot is at /dev/sda1
# (or /dev/xvda), it's the root volume - leave this empty so Terraform
# doesn't attach a duplicate. Only set this when there's a *separate* data
# snapshot you want mounted as /dev/sdb.
data_volume_snapshot_id = ""

# Match the AMI's root snapshot size (visible in BlockDeviceMappings.Ebs.VolumeSize)
root_volume_size_gib = 20

# Default 22. Change only if your sshd_config listens on a different port.
sftp_port = 22

# CIDR of the perimeter ingress VPC where the NLB lives. Default is correct
# for this LZA setup (HomeRegionIngressCidr in replacements-config.yaml).
ingress_vpc_cidr = "10.0.0.0/20"

# Optional. Set to the EC2 Instance Connect Endpoint SG ID in shared-prod
# to allow admin SSH via EICE. Get with:
#   aws ec2 describe-instance-connect-endpoints --region us-east-2 \
#     --filters Name=vpc-id,Values=<shared-prod-vpc-id> \
#     --query 'InstanceConnectEndpoints[].SecurityGroupIds'
# eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
