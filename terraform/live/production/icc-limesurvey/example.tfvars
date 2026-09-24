###############################################################################
# Copy to terraform.tfvars and fill ami_id.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "icc-limesurvey"
region       = "us-east-2"

name          = "icc-limesurvey"
instance_type = "t3.small"
ami_id        = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

private_ip           = "10.12.1.83"
root_volume_size_gib = 8

app_ports        = [80, 443]
ingress_vpc_cidr = "10.0.0.0/20"
