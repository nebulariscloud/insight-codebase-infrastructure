###############################################################################
# SFTP VOFeeling (Production / shared-prod)
#
# Lift-and-shift of "SFTP VOFeeling" from the source tenant
# (254422596287 / us-east-1, i-0729b47a59c8b756d) into shared-prod /
# us-east-2. Private box serving SFTP (TCP/22), fronted by the perimeter
# ingress NLB (sibling leaf terraform/live/perimeter/sftp-voice-feeling-nlb/),
# which targets this instance's private IP over TGW.
#
# Standard clean migration. Source root volume is 80 GiB gp3 and UNENCRYPTED,
# so the cross-account copy simply re-encrypts with the LZA EBS key (no
# customer-CMK share needed). See README.
#
# Same private-only-behind-ingress-NLB shape as
# terraform/live/production/sftp-server/. This leaf has no S3/amex bucket
# grant (that was specific to the recordings SFTP server); the instance role
# carries only SSM + CloudWatch Agent + Session Manager KMS.
###############################################################################

locals {
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

  # Dedicated instance profile defined in iam.tf. Carries the same SSM and
  # CloudWatch Agent permissions LZA's default role provides, minus the amex
  # bucket grant the sftp-server leaf adds (this box doesn't use it).
  iam_instance_profile = aws_iam_instance_profile.sftp.name

  # First-boot bootstrap. Runs only on a fresh instance launch (cloud-init
  # marks user_data as processed after the first run). Used to:
  #   1. Whitelist the perimeter ingress CIDR in fail2ban so the NLB's
  #      private IPs (which all client traffic appears to come from since
  #      preserve_client_ip=false) never get banned.
  #   2. Install the EC2 Instance Connect agent so admins can SSH via EICE.
  #   3. Ensure the SSM agent is installed/running so the box is
  #      Session-Manager-reachable.
  #   4. Restart sshd as a safety net.
  # The script is idempotent and tolerates missing services / tools, so it
  # works on Amazon Linux 2/2023, Ubuntu, RHEL/CentOS, Debian, etc.
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
        printf '\n[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 10.0.0.0/20\n' >> "$JAIL_LOCAL"
      fi
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

    # ---- SSM agent -----------------------------------------------------------
    # Amazon Linux 2/2023 and Ubuntu (16.04+) ship amazon-ssm-agent
    # pre-installed. Debian does NOT, which is why past migrated SFTP AMIs
    # showed up "offline" in SSM until the agent was installed by hand. Bake
    # it into first boot so future replacements come up Session-Manager-ready.
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^amazon-ssm-agent\.service'; then
      echo "[bootstrap] installing amazon-ssm-agent"
      REGION=$(curl -fs --max-time 5 -H "X-aws-ec2-metadata-token: $(curl -fs --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-2")
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64) DEB_ARCH=amd64 ;;
        aarch64) DEB_ARCH=arm64 ;;
        *) DEB_ARCH=amd64 ;;
      esac
      if command -v dpkg >/dev/null 2>&1; then
        TMP=$(mktemp -d)
        if curl -fsSL --max-time 60 \
             "https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/debian_$${DEB_ARCH}/amazon-ssm-agent.deb" \
             -o "$${TMP}/amazon-ssm-agent.deb"; then
          dpkg -i "$${TMP}/amazon-ssm-agent.deb" || apt-get install -fy
        fi
        rm -rf "$${TMP}"
      elif command -v rpm >/dev/null 2>&1; then
        rpm -ivh --replacepkgs \
          "https://s3.$${REGION}.amazonaws.com/amazon-ssm-$${REGION}/latest/linux_$${DEB_ARCH}/amazon-ssm-agent.rpm" || true
      fi
    fi
    systemctl enable --now amazon-ssm-agent 2>/dev/null || \
      systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
    echo "[bootstrap] ssm agent: $(systemctl is-active amazon-ssm-agent 2>/dev/null || echo unknown)"

    # ---- sshd safety reload --------------------------------------------------
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null

    echo "[bootstrap] done: $(date -u)"
  EOT

  # Inbound: SFTP only, scoped to the Perimeter ingress VPC CIDR. The NLB has
  # preserve_client_ip=false, so the box only sees NLB private IPs in the
  # perimeter ingress range. Partner-IP allowlisting is enforced at the NLB
  # SG layer (see the sibling nlb leaf's allowed_source_cidrs).
  ingress_rules = [
    {
      from_port   = var.sftp_port
      to_port     = var.sftp_port
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "SFTP from perimeter ingress NLB"
    },
  ]

  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  imdsv2_required         = true
  monitoring              = false # ec2:MonitorInstances not in the TF allow-policy
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role = "sftp"
  }
}

###############################################################################
# Optional EICE access (admin SSH via EC2 Instance Connect Endpoint)
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
# Outputs - the NLB leaf reads private_ip from this stack's output and plugs
# it into its own tfvars. (One-time, manual hand-off; matches sftp-nlb.)
###############################################################################

output "instance_id" {
  description = "EC2 instance ID for the SFTP server."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Paste into terraform/live/perimeter/sftp-voice-feeling-nlb/terraform.tfvars as sftp_server_private_ip."
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
