###############################################################################
# Copy to terraform.tfvars and fill ami_id.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-db-1"
region       = "us-east-2"

name          = "aheeva-db-1"
instance_type = "m5.2xlarge"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

private_ip           = "10.12.1.81"
root_volume_size_gib = 200
