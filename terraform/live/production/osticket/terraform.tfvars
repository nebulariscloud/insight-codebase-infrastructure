###############################################################################
# osTicket (Production / shared-prod)
#
# Migrated off Lightsail `osticket1` in the source tenant (254422596287,
# us-east-1, static IP 204.236.253.33, 512 MB / 2 vCPU / 20 GB).
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "osticket"
region       = "us-east-2"

name = "osticket"

# Source Lightsail plan was 512 MB / 2 vCPU. t3a.micro (1 GB / 2 vCPU) is the
# smallest sensible EC2 equivalent — t3a.nano matches RAM exactly but leaves no
# headroom for effectively no saving.
instance_type = "t3a.micro"

# Registered from the Lightsail snapshot export chain:
#   lightsail export-snapshot -> ami-00eabb892818fe746 (source tenant, aws/ebs)
#   -> copy-snapshot re-encrypted to transfer CMK e861c20e-... -> snap-0de2c604079d26516
#   -> shared to Production -> copy-snapshot to us-east-2 w/ LZA EBS key -> snap-04d151958cfa98c62
#   -> register-image -> this AMI. No marketplace product code (verified).
ami_id = "ami-069893c2d380d4dfb"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a (us-east-2a)

# Pinned so the ALB target stays stable across instance replacements.
# Verified free in app-a at build time (used: .16 .50 .51 .60 .61 .65 .70 .71
# .78 .121 .174 .192; .66 is reserved for ws-aheeva).
private_ip = "10.12.1.67"

# Source Lightsail disk was 20 GB; destination is gp3 (set in main.tf).
root_volume_size_gib = 20

# osTicket is Apache on 80. TLS terminates at the ALB, so 443 is not needed on
# the instance — but kept for parity with the other webapps and in case the
# in-AMI vhost already listens on it.
app_ports        = [80, 443]
ingress_vpc_cidr = "10.0.0.0/20"

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
