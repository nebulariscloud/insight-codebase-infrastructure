###############################################################################
# Webapps PHP 7.3 — Wave 1. Fill ami_id + subnet_id before apply.
# NOTE: source AMI is CMK-encrypted; share the CMK to Production before copy.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "webapps-php73"
region       = "us-east-2"

name          = "webapps-php73"
instance_type = "t3a.micro"

# Re-encrypted AMI in us-east-2 (source aws/ebs key → transfer-CMK workaround →
# register-image from the re-encrypted snapshot). Set to the PHP_DEST_AMI value.
ami_id = "ami-0e640042d0e46dcf2"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a

# Pinned so the ALB target stays stable across instance replacements.
private_ip = "10.12.1.61"

root_volume_size_gib = 40

app_ports        = [80, 443]
ingress_vpc_cidr = "10.0.0.0/20"

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
