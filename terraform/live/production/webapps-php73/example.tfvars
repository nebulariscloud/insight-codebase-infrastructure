###############################################################################
# Copy to terraform.tfvars and fill in.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "webapps-php73"
region       = "us-east-2"

name          = "webapps-php73"
instance_type = "t3a.micro"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# private_ip = "10.12.1.61"

root_volume_size_gib = 40
app_ports            = [80, 443]
ingress_vpc_cidr     = "10.0.0.0/20"

# eice_security_group_id = "sg-XXXXXXXXXXXXXXXXX"
