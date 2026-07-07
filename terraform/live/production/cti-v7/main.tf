###############################################################################
# Aheeva CTI v7 (Production / shared-prod) — Option B: direct-EIP SIP endpoint
#
# Lift-and-shift of the Aheeva CTI v7 server from the source tenant
# (254422596287 / us-east-1, i-03f52a172a049b1a8, EIP 54.152.253.96) into
# shared-prod / us-east-2.
#
# WHY THIS LEAF IS DIFFERENT FROM EVERY OTHER PRODUCTION LEAF:
#   CTI v7 is a SIP endpoint. SIP trunks do NOT register (IP-authenticated,
#   peer-to-peer), RTP media terminates directly on the box (no SBC), and
#   Aheeva's config hardcodes externip to the box's own public IP. That means
#   the box CANNOT sit behind NAT the way the SFTP/webapp migrations do — it
#   needs a directly-attached public IP (an EIP on its own ENI) so RTP works
#   and so the Aheeva license (keyed to the public IP) validates.
#
#   This is the "Option B" shape from docs/07-Operations/cti-v7-migration-
#   options.md: a scoped exception to the LZA workload guardrails so this one
#   tagged instance may have an IGW-routed public subnet and an EIP. See the
#   README for the exception PRs that must land BEFORE this leaf can apply.
#
# PREREQUISITES (all in the README, all must exist before apply):
#   1. Public subnet + IGW + public route table in shared-prod (network-config.yaml).
#   2. VPC Block Public Access exclusion for that subnet.
#   3. SCP exception allowing ec2:AllocateAddress / ec2:AssociateAddress for
#      resources tagged Migrated == CTIv7 in this account.
#   4. The CTI v7 AMI copied + re-encrypted into us-east-2 (source is unencrypted).
#   5. Aheeva vendor has re-allowlisted the new EIP on their License Server.
###############################################################################

locals {
  # The instance carries this tag so the scoped SCP exception applies to it
  # (and only it). Do not reuse this tag value on other instances.
  migration_tag = "CTIv7"

  # SIP signaling: UDP 5060 from each SIP peer (the VoIP gateway path).
  sip_rules = [
    for cidr in var.sip_peer_cidrs : {
      from_port   = 5060
      to_port     = 5060
      protocol    = "udp"
      cidr_blocks = [cidr]
      description = "SIP UDP 5060 from VoIP gateway ${cidr}"
    }
  ]

  # RTP media: UDP 10000-11000 from the SIP peers plus the confirmed extra
  # RTP sources (including the intentional 1.1.1.1 Aheeva special config).
  rtp_cidrs = concat(var.sip_peer_cidrs, var.rtp_extra_cidrs)
  rtp_rules = [
    for cidr in local.rtp_cidrs : {
      from_port   = var.rtp_from_port
      to_port     = var.rtp_to_port
      protocol    = "udp"
      cidr_blocks = [cidr]
      description = "RTP media ${var.rtp_from_port}-${var.rtp_to_port} from ${cidr}"
    }
  ]

  # Admin 8443 web GUI — only from the perimeter ingress ALB (TLS-terminated
  # there with an IP allowlist on the listener). The instance never exposes
  # 8443 to the public internet directly.
  admin_rules = [
    {
      from_port   = 8443
      to_port     = 8443
      protocol    = "tcp"
      cidr_blocks = [var.admin_ingress_cidr]
      description = "Aheeva admin web GUI 8443 from perimeter ingress ALB"
    }
  ]

  ingress_rules = concat(local.sip_rules, local.rtp_rules, local.admin_rules)

  # Resolve the LZA EBS key ARN automatically unless overridden in tfvars.
  ebs_kms_key_arn = var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : data.aws_kms_key.ebs.arn
}

# LZA-managed default EBS encryption key in this account/region. Used to encrypt
# the CTI v7 root volume (source is unencrypted; destination must be encrypted).
data "aws_kms_key" "ebs" {
  key_id = "alias/accelerator/ebs/default-encryption/key"
}

module "ec2_migrated" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.public_subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip

  # SSH key pair for admin access. The migrated CentOS disk carries the
  # original box's "Aheeva" authorized_keys, but we don't hold that private
  # key. Attaching our own key_name makes cloud-init inject our public key on
  # boot so we can SSH in. NOTE: SSM/EC2 Instance Connect don't work on this
  # box (no agent baked into the CentOS 7 image). Changing key_name replaces
  # the instance.
  key_name = var.key_name

  # Direct EIP — the whole point of Option B. Requires the SCP exception
  # (ec2:AllocateAddress / ec2:AssociateAddress) to be in place first.
  allocate_eip = true

  # LZA default SSM role for admin access at the OS level (Session Manager).
  # SIP admin is the 8443 GUI; OS admin is SSM.
  iam_instance_profile = "EC2-Default-SSM-Role"

  ingress_rules = local.ingress_rules

  # Source root volume is 200 GiB, unencrypted gp2. Destination is gp3,
  # encrypted with the LZA EBS key (re-encrypt happens at AMI copy; this
  # pins the runtime volume encryption too).
  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  imdsv2_required = true
  # Detailed (1-minute) monitoring is intentionally OFF: the TerraformExecution
  # allow-policy does not grant ec2:MonitorInstances, so monitoring=true fails
  # the apply with UnauthorizedOperation. Basic 5-minute CloudWatch metrics are
  # still collected. Flip to true only after adding ec2:MonitorInstances to
  # aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json
  # (an LZA pipeline change).
  monitoring              = false
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role     = "cti-v7"
    Migrated = local.migration_tag
  }
}

###############################################################################
# Outputs
###############################################################################

output "instance_id" {
  description = "EC2 instance ID for CTI v7."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP inside the shared-prod public subnet."
  value       = module.ec2_migrated.private_ip
}

output "public_ip" {
  description = <<-EOT
    The allocated EIP. THIS is the IP to give the Aheeva vendor for the
    license re-allowlist, and to set as externip in Aheeva's sip.conf at
    cutover (replacing the source 54.152.253.96).
  EOT
  value       = module.ec2_migrated.public_ip
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}

output "availability_zone" {
  description = "AZ CTI v7 landed in."
  value       = module.ec2_migrated.availability_zone
}
