###############################################################################
# Aheeva Asterisk 1 — private lift-and-shift from source tenant 254422596287 /
# us-east-1 (i-0783051c356bb7753). Source root 100 GiB gp2, unencrypted.
# Private in shared-prod-app-a; carriers reach it over the Site-to-Site VPNs.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-asterisk-1"
region       = "us-east-2"

name          = "aheeva-asterisk-1"
instance_type = "m5.2xlarge"

# Copied + re-encrypted into us-east-2 with the LZA EBS key. Fill after copy.
ami_id = "ami-XXXXXXXXXXXXXXXXX"

# shared-prod VPC + app-a subnet (private).
#   vpc-04a8720d0ddb40713     = AWSAccelerator-us-east-2-shared-prod
#   subnet-00d31cac6422417c4  = AWSAccelerator-us-east-2-shared-prod-app-a
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned. app-a in-use: .16 .50 .51 .60 .61 .62 .65 .66 .67 .70 .71 .121 .174
# .192. .80/.81/.82 is a clean contiguous block for the Aheeva cluster.
private_ip = "10.12.1.80"

root_volume_size_gib = 100

# SG scopes. Voice defaults to the VPN on-prem ranges (see variables.tf);
# prune at the voice cutover. db/admin default to the app subnet.
# intra_cluster_cidrs / voice_source_cidrs / db_client_cidrs / admin_cidrs
# all take their variables.tf defaults unless overridden here.

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
