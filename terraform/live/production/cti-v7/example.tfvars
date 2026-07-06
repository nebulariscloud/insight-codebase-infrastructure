###############################################################################
# Copy to terraform.tfvars and fill in the placeholders.
#
# DO NOT apply until the Option B guardrail-exception prerequisites are in
# place (see README). Until then this is a design draft that CI will plan but
# apply will fail (no public subnet, SCP denies AllocateAddress).
#
# Discovery (CloudShell, signed in to Production / us-east-2):
#
#   # VPC
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*shared-prod*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   # The PUBLIC subnet added by the exception (won't exist until then)
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
#     "Name=tag:Name,Values=*shared-prod-public*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
#
#   # LZA EBS key ARN
#   aws kms describe-key --region us-east-2 \
#     --key-id alias/accelerator/ebs/default-encryption/key \
#     --query 'KeyMetadata.Arn' --output text
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "cti-v7"
region       = "us-east-2"

name          = "cti-v7"
instance_type = "m5.2xlarge"

# Placeholder — set to the copied+re-encrypted AMI in us-east-2.
ami_id = "ami-XXXXXXXXXXXXXXXXX"

vpc_id           = "vpc-04a8720d0ddb40713"
public_subnet_id = "subnet-XXXXXXXXXXXXXXXXX"

# Optional: pin a private IP inside the public subnet CIDR.
# private_ip = "10.12.9.50"

# Source root volume is 200 GiB (unencrypted gp2). Destination is encrypted gp3.
root_volume_size_gib = 200

# LZA EBS key ARN (resolve with the kms describe-key command above).
ebs_kms_key_arn = "arn:aws:kms:us-east-2:395516496764:key/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"

# SIP/RTP peers — Liberty data center (the VoIP gateway path).
sip_peer_cidrs = [
  "199.116.62.102/32",
  "23.249.138.106/32",
]

# Extra RTP sources confirmed still needed. 1.1.1.1/32 is an INTENTIONAL
# Aheeva special config (vendor-confirmed) — keep it. 196.12.161.225 was
# dropped (no longer needed for v7).
rtp_extra_cidrs = [
  "64.89.2.105/32",
  "66.231.161.164/32",
  "1.1.1.1/32",
]

# RTP range — matches Asterisk rtpstart=10000 / rtpend=11000 on the source.
rtp_from_port = 10000
rtp_to_port   = 11000

# Admin 8443 GUI reachable only from the perimeter ingress ALB. Public admin
# allowlist lives on the ALB listener rule, not on this instance SG.
admin_ingress_cidr = "10.0.0.0/20"
