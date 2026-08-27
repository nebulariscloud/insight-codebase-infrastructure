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
stack_name   = "sftp-server-f9"
region       = "us-east-2"

name          = "sftp-server-f9"
instance_type = "t3.medium"
ami_id        = "ami-0545c53be16039a74"

vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# Pin the private IP so the NLB target stays stable across instance rebuilds.
# Pick an unused address inside the chosen subnet's CIDR.
# private_ip = "10.12.1.52"

# This AMI's root snapshot is at /dev/xvda (20 GiB gp3, encrypted) and is
# already baked into ami-0545c53be16039a74. Leave empty unless there's a
# *separate* data snapshot you want mounted as /dev/sdb.
data_volume_snapshot_id = ""

# Match the AMI's source root size (20 GiB).
root_volume_size_gib = 20

# Default 22. Change only if your sshd_config listens on a different port.
sftp_port = 22

# CIDR of the perimeter ingress VPC where the NLB lives. Default is correct
# for this LZA setup (HomeRegionIngressCidr in replacements-config.yaml).
ingress_vpc_cidr = "10.0.0.0/20"

# Optional. Set to the EC2 Instance Connect Endpoint SG ID in shared-prod
# to allow admin SSH via EICE.
# eice_security_group_id = "sg-0a990a87e6abca926"

# Set once the f9-recordings bucket is on SSE-KMS. See variables.tf for the
# discovery command.
# f9_bucket_kms_key_arn = "arn:aws:kms:us-east-2:395516496764:key/adacb68f-a099-486c-bfce-56bb696ed126"
