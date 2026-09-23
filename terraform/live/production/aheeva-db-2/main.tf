###############################################################################
# Aheeva DB 2 (Production / shared-prod) — private lift-and-shift
#
# Lift-and-shift of "Aheeva DB 2" from the source tenant
# (254422596287 / us-east-1, i-097ec187250e48e21, 10.0.100.131) into
# shared-prod / us-east-2. Part of the CTI v7 / IVR cluster.
#
# PRIVATE, no load balancer, no EIP. Reached over shared-prod / TGW by the
# cluster peers, and over the Site-to-Site VPNs by any on-prem consumers.
# Source root volume is 200 GiB gp2, UNENCRYPTED — the cross-account copy
# re-encrypts with the LZA EBS key (no customer-CMK share). See README.
#
# The three Aheeva boxes shared one SG (AheevaV7) in the source, so the same
# scoped rule shape is reproduced here. On a DB box the voice rules are inert
# unless it also runs Aheeva voice roles; kept behind var.voice_source_cidrs.
###############################################################################

locals {
  intra_rules = concat(
    [for c in var.intra_cluster_cidrs : {
      from_port   = var.sip_port
      to_port     = var.sip_port
      protocol    = "tcp"
      cidr_blocks = [c]
      description = "Intra-cluster SIP ${var.sip_port}/tcp from ${c}"
    }],
    [for c in var.intra_cluster_cidrs : {
      from_port   = var.sip_port
      to_port     = var.sip_port
      protocol    = "udp"
      cidr_blocks = [c]
      description = "Intra-cluster SIP ${var.sip_port}/udp from ${c}"
    }],
  )

  rtp_rules = [for c in var.voice_source_cidrs : {
    from_port   = var.rtp_from_port
    to_port     = var.rtp_to_port
    protocol    = "udp"
    cidr_blocks = [c]
    description = "RTP ${var.rtp_from_port}-${var.rtp_to_port}/udp from VPN ${c}"
  }]

  voice_tcp_rules = flatten([
    for p in var.voice_tcp_ports : [
      for c in var.voice_source_cidrs : {
        from_port   = p
        to_port     = p
        protocol    = "tcp"
        cidr_blocks = [c]
        description = "Aheeva voice ${p}/tcp from VPN ${c}"
      }
    ]
  ])

  voice_5002_rules = [for c in var.voice_source_cidrs : {
    from_port   = 5002
    to_port     = 5004
    protocol    = "tcp"
    cidr_blocks = [c]
    description = "Aheeva 5002-5004/tcp from VPN ${c}"
  }]

  db_rules = [for c in var.db_client_cidrs : {
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = [c]
    description = "MySQL ${var.db_port} from ${c}"
  }]

  admin_rules = flatten([
    for p in [22, 8443] : [
      for c in var.admin_cidrs : {
        from_port   = p
        to_port     = p
        protocol    = "tcp"
        cidr_blocks = [c]
        description = "Admin ${p}/tcp from ${c}"
      }
    ]
  ])

  ingress_rules = concat(
    local.intra_rules,
    local.rtp_rules,
    local.voice_tcp_rules,
    local.voice_5002_rules,
    local.db_rules,
    local.admin_rules,
  )

  ebs_kms_key_arn = var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : data.aws_kms_key.ebs.arn
}

data "aws_kms_key" "ebs" {
  key_id = "alias/accelerator/ebs/default-encryption/key"
}

module "ec2_migrated" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip
  key_name      = var.key_name

  iam_instance_profile = "EC2-Default-SSM-Role"

  ingress_rules = local.ingress_rules

  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  user_data = <<-EOT
    #!/bin/bash
    set +e
    exec > >(tee /var/log/aheeva-bootstrap.log) 2>&1
    echo "[bootstrap] start: $(date -u)"
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^amazon-ssm-agent\.service'; then
      REGION=$(curl -fs --max-time 5 -H "X-aws-ec2-metadata-token: $(curl -fs --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-2")
      ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) A=amd64;; esac
      if command -v dpkg >/dev/null 2>&1; then
        T=$(mktemp -d)
        curl -fsSL --max-time 60 "https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/debian_$${A}/amazon-ssm-agent.deb" -o "$${T}/a.deb" && dpkg -i "$${T}/a.deb" || apt-get install -fy
        rm -rf "$${T}"
      elif command -v rpm >/dev/null 2>&1; then
        rpm -ivh --replacepkgs "https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${A}/amazon-ssm-agent.rpm" || true
      fi
    fi
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
    echo "[bootstrap] done: $(date -u)"
  EOT

  imdsv2_required         = true
  monitoring              = false # ec2:MonitorInstances not in the TF allow-policy
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role    = "aheeva-db"
    Cluster = "cti-v7"
  }
}

resource "aws_vpc_security_group_ingress_rule" "eice_ssh" {
  count = var.eice_security_group_id == "" ? 0 : 1

  security_group_id            = module.ec2_migrated.security_group_id
  referenced_security_group_id = var.eice_security_group_id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "Admin SSH from EC2 Instance Connect Endpoint"
}

###############################################################################
# Outputs
###############################################################################

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Cluster peers and VPN routing target this."
  value       = module.ec2_migrated.private_ip
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}

output "availability_zone" {
  description = "AZ the instance landed in."
  value       = module.ec2_migrated.availability_zone
}
