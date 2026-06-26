###############################################################################
# Moodle (Production / shared-prod)
#
# Lift-and-shift from a Lightsail "IT-Moodle-LAMP_PHP_8-3-16" instance in
# us-east-1. The original Bitnami Moodle stack (Apache + MariaDB + PHP-FPM)
# is preserved end-to-end; only the surrounding network changes:
#
#   Before (Lightsail us-east-1)
#     Internet -> Lightsail static IP 54.165.163.95 -> instance (public)
#
#   After (LZA us-east-2)
#     Internet -> Perimeter ingress ALB -> TGW -> this instance (private)
#
# Migration path that landed the AMI used here:
#   1. Lightsail "create-instance-snapshot" -> "export-snapshot" (source acct).
#   2. Re-encrypt the EBS snapshot under a customer-managed CMK in source
#      (default AWS-managed aws/ebs key cannot be shared cross-account).
#   3. modify-snapshot-attribute --add user_id=395516496764 to share.
#   4. In Production / us-east-2: copy-snapshot cross-region, re-encrypting
#      under alias/accelerator/ebs/default-encryption/key.
#   5. register-image from the destination snapshot. Result: var.ami_id.
#
# The sibling leaf `terraform/live/perimeter/moodle-alb/` (to be added when
# we wire DNS) creates the ALB target group and host-header rule; it reads
# this leaf's private_ip output. Same pattern as sftp-server/sftp-nlb.
#
# In-OS cutover edits (one-time, via SSM Session Manager after first launch):
#   /opt/bitnami/apache/htdocs/config.php
#     $CFG->wwwroot  = 'https://moodle.<corp>.com';
#     $CFG->sslproxy = true;   # ALB terminates TLS; without this Moodle
#                              # generates http:// redirects and the login
#                              # flow loops.
#   sudo /opt/bitnami/ctlscript.sh restart apache
###############################################################################

module "ec2_migrated" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip

  # Dedicated instance profile defined in iam.tf. Mirrors the SSM and
  # CloudWatch Agent managed policies LZA puts on its shared
  # EC2-Default-SSM-Role, and adds the kms:Decrypt + kms:GenerateDataKey
  # grant Session Manager needs against the LZA-managed
  # accelerator/sessionmanager-logs/session CMK.
  #
  # Why dedicated, not the module default ("EC2-Default-SSM-Role"):
  #   - LZA tags its role Accelerator=AWSAccelerator, so SCPs deny
  #     iam:PutRolePolicy from Terraform on it (we can't customise).
  #   - We've hit "InvalidParameterValue: Invalid IAM Instance Profile
  #     name" against the LZA-provisioned profile in practice; a
  #     Terraform-managed profile is the predictable path.
  iam_instance_profile = aws_iam_instance_profile.moodle.name
  key_name             = var.key_name

  # First-boot bootstrap. The Bitnami Debian 12 Moodle AMI does NOT ship
  # with amazon-ssm-agent (Debian, not Ubuntu/AL). Without this script the
  # instance comes up but never registers with SSM, leaving no admin path
  # in. The block below is idempotent and tolerates missing tools, so it
  # also works if we ever swap the AMI for a non-Bitnami base.
  user_data = <<-EOT
    #!/bin/bash
    set +e
    exec > >(tee /var/log/moodle-bootstrap.log) 2>&1
    echo "[bootstrap] start: $(date -u)"

    # ---- SSM agent -----------------------------------------------------------
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^amazon-ssm-agent\.service'; then
      echo "[bootstrap] installing amazon-ssm-agent"
      TOKEN=$(curl -fs --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
      REGION=$(curl -fs --max-time 5 -H "X-aws-ec2-metadata-token: $${TOKEN}" \
        http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-2")
      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64)  DEB_ARCH=amd64 ;;
        aarch64) DEB_ARCH=arm64 ;;
        *)       DEB_ARCH=amd64 ;;
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

    # ---- Bitnami stack health check -----------------------------------------
    # Bitnami's services are managed by ctlscript.sh, not native systemd
    # units in this AMI generation. Confirm Apache and MariaDB came up.
    if [ -x /opt/bitnami/ctlscript.sh ]; then
      /opt/bitnami/ctlscript.sh status 2>&1 | sed 's/^/[bootstrap] bitnami: /'
    fi

    echo "[bootstrap] done: $(date -u)"
  EOT

  # Inbound: HTTP from the perimeter ingress VPC only. The ALB terminates
  # TLS upstream; the instance speaks plain HTTP behind it. Locking to the
  # ingress VPC CIDR (10.0.0.0/20) means only the ALB can reach Apache.
  ingress_rules = concat(
    [
      {
        from_port   = var.moodle_http_port
        to_port     = var.moodle_http_port
        protocol    = "tcp"
        cidr_blocks = [var.ingress_vpc_cidr]
        description = "HTTP from perimeter ingress ALB"
      },
    ],
    var.extra_ingress_rules,
  )

  root_volume_size = var.root_volume_size_gib
  root_volume_type = "gp3"

  # No extra data volume. The Lightsail bundle is single-volume; Moodle
  # files (/var/moodledata) and MariaDB (/var/lib/mysql) both live on the
  # root volume and migrate with the AMI.
  additional_ebs_volumes = []

  imdsv2_required = true
  # Detailed (1-minute) CloudWatch monitoring requires ec2:MonitorInstances,
  # which the LZA TerraformExecution role's allow-policy doesn't grant. The
  # default 5-minute basic monitoring is sufficient for an internal LMS; if
  # we later need 1-minute metrics, add MonitorInstances/UnmonitorInstances
  # to aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json
  # and flip this back to true.
  monitoring              = false
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role     = "moodle"
    Migrated = "true"
  }
}

###############################################################################
# Optional EICE access (admin SSH via EC2 Instance Connect Endpoint)
#
# SSM Session Manager is the primary access path. EICE is a fallback for
# the case where the SSM agent fails to register (e.g., a future AMI
# rebuild that breaks the bootstrap script). Wired in only when
# var.eice_security_group_id is set in tfvars.
###############################################################################

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
# Outputs - the perimeter ALB leaf (sibling) reads private_ip from this
# stack's output and plugs it into its target group registration.
###############################################################################

output "instance_id" {
  description = "EC2 instance ID for Moodle."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Paste into terraform/live/perimeter/moodle-alb/terraform.tfvars as moodle_private_ip when the ALB leaf is created."
  value       = module.ec2_migrated.private_ip
}

output "availability_zone" {
  description = "AZ Moodle landed in."
  value       = module.ec2_migrated.availability_zone
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}
