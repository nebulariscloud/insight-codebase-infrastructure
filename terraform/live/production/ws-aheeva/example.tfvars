###############################################################################
# Copy to terraform.tfvars and fill in.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "ws-aheeva"
region       = "us-east-2"

name          = "ws-aheeva"
instance_type = "t3a.medium"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

private_ip           = "10.12.1.66"
root_volume_size_gib = 80

ftps_control_port = 990
ftps_passive_from = 40000
ftps_passive_to   = 40500
ingress_vpc_cidr  = "10.0.0.0/20"

extra_app_ports = []
extra_app_cidrs = []

# eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
