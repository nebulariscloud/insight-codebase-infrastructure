###############################################################################
# Copy to terraform.tfvars and fill in. Same discovery commands as
# insight-ubuntu-prod/example.tfvars.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "insight-ubuntu-dev"
region       = "us-east-2"

name          = "insight-ubuntu-dev"
instance_type = "t3.medium"

vpc_id    = "vpc-XXXXXXXXXXXXXXXXX"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

private_ip = "10.12.1.XX"

root_volume_size_gib = 30

eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
