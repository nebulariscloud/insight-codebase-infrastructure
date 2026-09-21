###############################################################################
# Example values. The real ones live in terraform.tfvars, which IS committed
# (see .gitignore) because it contains nothing sensitive.
###############################################################################

account_name = "Production"
account_id   = "000000000000"
stack_name   = "aheeva-db-slave-v86"
region       = "us-east-2"

name          = "aheeva-db-slave-v86"
instance_type = "m5.2xlarge"

# Must be an AMI with NO marketplace product code, carrying both BDMs.
ami_id = "ami-00000000000000000"

vpc_id    = "vpc-00000000000000000"
subnet_id = "subnet-00000000000000000"

private_ip           = "10.12.1.54"
root_volume_size_gib = 200

db_port         = 3306
db_client_cidrs = ["10.12.0.0/16"]
admin_ssh_cidrs = []

key_name = ""
