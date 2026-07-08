###############################################################################
# Webapps Server — Wave 1. Fill ami_id + subnet_id before apply.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "webapps"
region       = "us-east-2"

name          = "webapps"
instance_type = "t3.small"

# Copied+re-encrypted AMI in us-east-2 (source was unencrypted → plain share).
ami_id = "ami-0edf797187c15c691"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a

# Pinned so the ALB target stays stable across instance replacements.
# NOTE: 10.12.1.60 was already in use in app-a; using .65 instead.
private_ip = "10.12.1.65"

root_volume_size_gib = 45

app_ports        = [80, 443]
ingress_vpc_cidr = "10.0.0.0/20"

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
