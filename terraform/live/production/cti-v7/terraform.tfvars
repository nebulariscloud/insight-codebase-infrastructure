###############################################################################
# CTI v7 — Option B (direct-EIP SIP endpoint).
#
# DRAFT: not applyable until the guardrail-exception prerequisites in README
# are live and the AMI is copied. Placeholders below are marked XXXX.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "cti-v7"
region       = "us-east-2"

name          = "cti-v7"
instance_type = "m5.2xlarge"

# Clean AMI in us-east-2 (Production) — marketplace product code stripped via
# source-tenant dd block-copy (the copy-image AMI ami-07b69272c5caf9d33 carried
# a delisted CentOS marketplace code that blocked RunInstances; this one is clean).
ami_id = "ami-0289fff8a491f450a"

# shared-prod VPC + the public subnet created by the Option B exception.
#
# public_subnet_id updated 2026-09-22 at un-park. History, because this ID has
# moved twice and the old values are traps:
#   subnet-0919739a39165a934  10.12.0.32/27   the ORIGINAL. cti-v7 ran here until
#                                             2026-08-08. LZA later recreated
#                                             public-a, orphaning this one and
#                                             dropping its RAM share to Production
#                                             - which is why RunInstances failed
#                                             with InvalidSubnetID.NotFound. Now
#                                             retagged ORPHANED-do-not-use-*.
#   subnet-0dc7b70d38275e775  10.12.0.192/27  the replacement. DELETED 2026-09-04
#                                             by the config-zip incident.
#   subnet-08ce7fb6c30eed107  10.12.0.192/27  CURRENT. Recreated 2026-09-10 and
#                                             verified shared to Production; VPC
#                                             BPA exclusion in place (2026-09-22).
vpc_id           = "vpc-04a8720d0ddb40713"
public_subnet_id = "subnet-08ce7fb6c30eed107"

root_volume_size_gib = 200

# SSH key pair for admin access (create it before applying — see variables.tf).
# Needed because this CentOS box has no SSM/EC2-Instance-Connect agent.
key_name = "cti-v7-admin"

# ebs_kms_key_arn left unset — the leaf auto-resolves
# alias/accelerator/ebs/default-encryption/key via a data source.

# SIP/RTP peers — Liberty data center (VoIP gateway path).
sip_peer_cidrs = [
  "199.116.62.102/32",
  "23.249.138.106/32",
]

# Extra RTP sources still needed. 1.1.1.1/32 is an intentional Aheeva special
# config (vendor-confirmed) — keep it. 196.12.161.225 dropped (obsolete for v7).
rtp_extra_cidrs = [
  "64.89.2.105/32",
  "66.231.161.164/32",
  "1.1.1.1/32",
]

rtp_from_port = 10000
rtp_to_port   = 11000

admin_ingress_cidr = "10.0.0.0/20"
