###############################################################################
# SFTP VOFeeling — lift-and-shift from source tenant 254422596287 / us-east-1
# (i-0729b47a59c8b756d). Source root volume unencrypted, 80 GiB gp3.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "sftp-voice-feeling"
region       = "us-east-2"

name          = "sftp-voice-feeling"
instance_type = "t3.micro"

# Copied + re-encrypted into us-east-2 with the LZA EBS key from the source
# AMI ami-0eb9130547efef27b (snapshot snap-026529127bece489a). See README.
ami_id = "ami-08530cb077a854142"

# Same VPC and subnet the other shared-prod SFTP boxes use:
#   vpc-04a8720d0ddb40713     = AWSAccelerator-us-east-2-shared-prod
#   subnet-00d31cac6422417c4  = AWSAccelerator-us-east-2-shared-prod-app-a
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned so the NLB target stays stable across instance replacements.
# Existing tenants in 10.12.1.0/24: .50 sftp-server, .61 webapps-php73,
# .71 insight-ubuntu-dev, .121 wazuh, .174 scriptcase. .62 is clear.
private_ip = "10.12.1.62"

# Match the source root volume size (80 GiB gp3).
root_volume_size_gib = 80

sftp_port        = 22
ingress_vpc_cidr = "10.0.0.0/20"

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.

# Optional EICE admin SSH. Same endpoint SG the sftp-server leaf uses.
# eice_security_group_id = "sg-0a990a87e6abca926"
