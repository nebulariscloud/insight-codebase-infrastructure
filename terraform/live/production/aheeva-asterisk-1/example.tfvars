###############################################################################
# Copy to terraform.tfvars and fill ami_id.
#
# Discovery (CloudShell, signed in to Production / us-east-2):
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-04a8720d0ddb40713" \
#     "Name=tag:Name,Values=*shared-prod-app*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone]' --output table
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-asterisk-1"
region       = "us-east-2"

name          = "aheeva-asterisk-1"
instance_type = "m5.2xlarge"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

private_ip           = "10.12.1.80"
root_volume_size_gib = 100

# Override the SG scopes only if the defaults (VPN ranges for voice, app subnet
# for db/admin) need tightening. See variables.tf for the defaults.
