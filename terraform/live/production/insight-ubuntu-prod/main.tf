###############################################################################
# Insight Ubuntu (Production)
#
# Private Ubuntu 22.04 LTS t3.medium in shared-prod. No public IP, no
# ingress from the internet, no ALB/NLB out front. Reachable only via
# SSM Session Manager (primary) or the EICE endpoint (fallback).
#
# Pairs with `insight-ubuntu-dev` (same shape, dev-side naming) so the
# client can iterate in dev without touching prod.
###############################################################################

# Canonical publishes the current Ubuntu 22.04 LTS AMD64 AMI ID in a
# well-known SSM parameter in every region. Reading it here means we
# don't hard-code an AMI that goes stale. The module already sets
# `lifecycle.ignore_changes = [ami, ...]`, so future rotations don't
# trigger silent instance replacements — bump the pinned AMI explicitly
# when we want to roll a fresh image in.
data "aws_ssm_parameter" "ubuntu_2204_amd64" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

module "ec2" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = data.aws_ssm_parameter.ubuntu_2204_amd64.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip

  # Dedicated instance profile. See iam.tf for rationale — we can't
  # customise LZA's EC2-Default-SSM-Role from Terraform (SCP-blocked),
  # and Session Manager needs the KMS grant on the LZA-managed
  # accelerator/sessionmanager-logs/session CMK.
  iam_instance_profile = aws_iam_instance_profile.this.name
  key_name             = var.key_name

  # Ubuntu 22.04 ships with amazon-ssm-agent pre-installed via snap. On
  # first boot, make sure it's enabled and running so the instance
  # registers with Session Manager without manual intervention.
  user_data = <<-EOT
    #!/bin/bash
    set +e
    exec > >(tee /var/log/insight-ubuntu-bootstrap.log) 2>&1
    echo "[bootstrap] start: $(date -u)"

    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || \
      systemctl enable --now amazon-ssm-agent 2>/dev/null || true
    echo "[bootstrap] ssm agent: $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || systemctl is-active amazon-ssm-agent 2>/dev/null || echo unknown)"

    echo "[bootstrap] done: $(date -u)"
  EOT

  # No ingress from the internet. No ALB/NLB. The workload does not
  # accept inbound calls from other servers. Admin access is via SSM
  # Session Manager (agent -> ssm.us-east-2.amazonaws.com, outbound
  # only). If EICE is later wired in via var.eice_security_group_id,
  # that adds TCP/22 from the EICE SG below.
  ingress_rules = []

  root_volume_size = var.root_volume_size_gib
  root_volume_type = "gp3"

  imdsv2_required = true
  # Detailed 1-minute CloudWatch monitoring needs ec2:MonitorInstances,
  # which the LZA TerraformExecution allow-policy does not currently
  # grant. Basic 5-minute metrics are fine here.
  monitoring              = false
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role        = "insight-ubuntu"
    Environment = "prod"
  }
}

###############################################################################
# Optional EICE access (admin SSH fallback via EC2 Instance Connect Endpoint)
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "eice_ssh" {
  count = var.eice_security_group_id == "" ? 0 : 1

  security_group_id            = module.ec2.security_group_id
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
  value       = module.ec2.instance_id
}

output "private_ip" {
  description = "Primary private IP."
  value       = module.ec2.private_ip
}

output "availability_zone" {
  description = "AZ the instance landed in."
  value       = module.ec2.availability_zone
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2.security_group_id
}

output "ami_id_used" {
  description = "Ubuntu 22.04 AMI ID resolved from Canonical's SSM parameter at apply time."
  value       = data.aws_ssm_parameter.ubuntu_2204_amd64.value
}
