###############################################################################
# WS Aheeva — Wave 2. Fill ami_id + subnet_id + ftps_client_cidrs before apply.
# The FINAL AMI is taken at cutover (mutable disk) — see README.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "ws-aheeva"
region       = "us-east-2"

name          = "ws-aheeva"
instance_type = "t3a.medium"

# Placeholder — set to the transfer-CMK re-encrypted AMI in us-east-2.
ami_id = "ami-XXXXXXXXXXXXXXXXX"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a

# Pin an unused app-a IP so the FTPS NLB target stays stable.
private_ip = "10.12.1.66"

root_volume_size_gib = 80

# FTPS: implicit-TLS control 990 + passive 40000-40500, from the ingress NLB.
ftps_control_port = 990
ftps_passive_from = 40000
ftps_passive_to   = 40500
ingress_vpc_cidr  = "10.0.0.0/20"

# Extra Aheeva app/admin ports — add only confirmed-in-use, scoped to admin IPs.
# Source SG had 8025/8078/8081/3389 etc. Left empty pending confirmation.
extra_app_ports = []
extra_app_cidrs = []

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
