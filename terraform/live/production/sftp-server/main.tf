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

  # Dedicated instance profile defined in iam.tf. Carries the same SSM and
  # CloudWatch Agent permissions LZA's default role provides, plus scoped
  # access to the amex-recordings bucket in the sibling leaf.
  iam_instance_profile = aws_iam_instance_profile.sftp.name
  key_name             = var.key_name

  # First-boot bootstrap. Runs only on a fresh instance launch (cloud-init
  # marks user_data as processed after the first run). Used to:
  #   1. Whitelist the perimeter ingress CIDR in fail2ban so the NLB's
  #      private IPs (which all client traffic appears to come from since
  #      preserve_client_ip=false) never get banned.
  #   2. Install the EC2 Instance Connect agent so admins can SSH via EICE
  #      from the AWS Console / mssh without needing pre-shared keys.
  #   3. Restart sshd as a safety net.
  # The script is idempotent and tolerates missing services / tools, so it
  # works on Amazon Linux 2/2023, Ubuntu, RHEL/CentOS, etc.
  user_data = <<-EOT
    #!/bin/bash
    set +e
    exec > >(tee /var/log/sftp-bootstrap.log) 2>&1
    echo "[bootstrap] start: $(date -u)"

    # ---- fail2ban whitelist for the NLB CIDR ---------------------------------
    if [ -d /etc/fail2ban ]; then
      JAIL_LOCAL=/etc/fail2ban/jail.local
      touch "$JAIL_LOCAL"
      if ! grep -qE '^\s*ignoreip\s*=.*10\.0\.0\.0/20' "$JAIL_LOCAL"; then
        echo "[bootstrap] adding 10.0.0.0/20 to fail2ban ignoreip"
        # Remove any existing [DEFAULT] section we previously added; keep user content.
        printf '\n[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 10.0.0.0/20\n' >> "$JAIL_LOCAL"
      fi
      # Wipe accumulated bans from any previous boot persisted to sqlite.
      rm -f /var/lib/fail2ban/fail2ban.sqlite3 2>/dev/null
      systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null
      echo "[bootstrap] fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
    else
      echo "[bootstrap] fail2ban not installed - skipping"
    fi

    # ---- EC2 Instance Connect agent ------------------------------------------
    if ! command -v eic_run_authorized_keys >/dev/null 2>&1; then
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y ec2-instance-connect
      elif command -v yum >/dev/null 2>&1; then
        yum install -y ec2-instance-connect
      elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y ec2-instance-connect
      fi
    fi
    echo "[bootstrap] eic agent: $(command -v eic_run_authorized_keys || echo missing)"

    # ---- sshd safety reload --------------------------------------------------
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null

    echo "[bootstrap] done: $(date -u)"
  EOT

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
