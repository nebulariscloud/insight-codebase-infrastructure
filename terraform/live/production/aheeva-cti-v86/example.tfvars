###############################################################################
# Example values. The real ones live in terraform.tfvars, which IS committed
# (see .gitignore) because it contains nothing sensitive.
###############################################################################

account_name = "Production"
account_id   = "000000000000"
stack_name   = "aheeva-cti-v86"
region       = "us-east-2"

name          = "aheeva-cti-v86"
instance_type = "c5.2xlarge"

# Must be an AMI with NO marketplace product code, carrying both BDMs.
ami_id = "ami-00000000000000000"

vpc_id           = "vpc-00000000000000000"
public_subnet_id = "subnet-00000000000000000" # PUBLIC subnet, IGW-routed

private_ip           = "10.12.0.196"
root_volume_size_gib = 185

# Never 0.0.0.0/0 on SIP. Empty means no SIP ingress, which is the safe default.
sip_peer_cidrs  = []
rtp_extra_cidrs = []
rtp_from_port   = 10000
rtp_to_port     = 20000

admin_ports        = [8443, 9443]
admin_ingress_cidr = "10.0.0.0/20"

db_port         = 3306
db_client_cidrs = ["10.12.1.54/32"] # the MariaDB replica

key_name = ""
