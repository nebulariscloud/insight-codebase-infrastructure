###############################################################################
# SFTP server (Production / shared-prod)
#
# Lift-and-shift from another AWS account. The AMI was already copied into
# us-east-2 so this leaf just launches it. Sibling leaf
# `terraform/live/perimeter/sftp-nlb/` exposes it to the internet through an
# NLB in the Perimeter ingress VPC; the NLB targets this instance by its
# private IP over TGW.
#
# Why no public IP / EIP here:
#   - shared-prod has internetGateway=false, so a public IP cannot route
#     anywhere even if the SCP allowed allocation.
#   - lza-core-workloads-guardrails-1 SCP denies ec2:AllocateAddress for
#     non-LZA principals. The NLB in Perimeter is what the partner
#     allowlists; the EC2 stays private-only.
###############################################################################

module "ec2_migrated" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip

  iam_instance_profile = var.iam_instance_profile
  key_name             = var.key_name

  # Inbound: SFTP only, scoped to the Perimeter ingress VPC CIDR. The NLB
  # has preserve_client_ip=false, so the manager only sees NLB private IPs
  # in the perimeter ingress range. Locking inbound here gives partner-IP
  # allowlist enforcement at the LB layer (NLB SG) and only-from-NLB
  # enforcement at the instance layer.
  ingress_rules = [
    {
      from_port   = var.sftp_port
      to_port     = var.sftp_port
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "SFTP from perimeter ingress NLB"
    },
  ]

  root_volume_size = var.root_volume_size_gib
  root_volume_type = "gp3"

  # Attach the data volume only when a snapshot was provided. If the AMI
  # already contains everything (root-only baked snapshot), leave
  # data_volume_snapshot_id empty in tfvars and this list collapses.
  additional_ebs_volumes = var.data_volume_snapshot_id == "" ? [] : [
    {
      device_name = var.data_volume_device_name
      size        = var.data_volume_size_gib
      type        = "gp3"
      snapshot_id = var.data_volume_snapshot_id
    },
  ]

  imdsv2_required         = true
  monitoring              = true
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role = "sftp"
  }
}

###############################################################################
# Optional EICE access (admin SSH via EC2 Instance Connect Endpoint)
#
# When var.eice_security_group_id is non-empty, the SFTP server's instance SG
# is opened on TCP/22 from that source SG. This lets us SSH into the box from
# CloudShell via EICE for troubleshooting (no SSM agent required, no public
# IP, no bastion). The EICE endpoint itself is created out-of-band per the
# scriptcase-migration-guide; this just wires its SG into the server SG.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "eice_ssh" {
  count = var.eice_security_group_id == "" ? 0 : 1

  security_group_id            = module.ec2_migrated.security_group_id
  referenced_security_group_id = var.eice_security_group_id
  from_port                    = var.sftp_port
  to_port                      = var.sftp_port
  ip_protocol                  = "tcp"
  description                  = "Admin SSH from EC2 Instance Connect Endpoint"
}

###############################################################################
# Outputs - the NLB leaf reads private_ip from this stack's output and
# plugs it into its own tfvars. (One-time, manual hand-off; matches the
# pattern used by wazuh-nlb / wazuh-ga.)
###############################################################################

output "instance_id" {
  description = "EC2 instance ID for the SFTP server."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Paste into terraform/live/perimeter/sftp-nlb/terraform.tfvars as sftp_server_private_ip."
  value       = module.ec2_migrated.private_ip
}

output "availability_zone" {
  description = "AZ the SFTP server landed in."
  value       = module.ec2_migrated.availability_zone
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}
