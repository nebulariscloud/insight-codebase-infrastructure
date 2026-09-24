###############################################################################
# ICC LimeSurvey — lift-and-shift from source tenant 254422596287 / us-east-1
# (i-0c0ac0e3ee3edee20). All-in-one box (LimeSurvey + MySQL on one disk).
# Source root 8 GiB gp2, unencrypted, no marketplace product code.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "icc-limesurvey"
region       = "us-east-2"

name          = "icc-limesurvey"
instance_type = "t3.small"

# Copied + re-encrypted into us-east-2 with the LZA EBS key from source
# ami-09cdbe7e8664d5a46 (snap-01bd2b7df9e633a5e). Source unencrypted, no
# marketplace product code — plain copy-image, 2026-09-23.
ami_id = "ami-06840d25820d0a859"

# shared-prod VPC + app-a subnet (private).
#   vpc-04a8720d0ddb40713     = AWSAccelerator-us-east-2-shared-prod
#   subnet-00d31cac6422417c4  = AWSAccelerator-us-east-2-shared-prod-app-a
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned so the ALB target stays stable across instance replacements.
# app-a in use: .16 .50 .51 .60 .61 .62 .65 .66 .67 .70 .71 .80 .81 .82 .121
# .174 .192. .83 is the next free slot after the Aheeva cluster block.
private_ip = "10.12.1.83"

# Match the source root size (8 GiB). All-in-one box, single disk.
root_volume_size_gib = 8

app_ports        = [80, 443]
ingress_vpc_cidr = "10.0.0.0/20"

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
