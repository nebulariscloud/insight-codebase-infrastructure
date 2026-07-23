###############################################################################
# Insight Ubuntu (Development sibling of insight-ubuntu-prod)
#
# Same shape as insight-ubuntu-prod, different state, different IP.
# Deployed into the Production account because the LZA `shared-dev` VPC
# in this install has no app subnets shared to the Development account
# yet — the client asked for two similar boxes today, not next week, so
# both live in shared-prod with `-prod` / `-dev` naming to keep them
# distinguishable. Move to a separate account later if account-level
# isolation becomes a requirement.
###############################################################################

data "aws_ssm_parameter" "ubuntu_2204_amd64" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

###############################################################################
# ICC CRM API ingress (crm-alb, Perimeter, over TGW)
#
# The crm-alb leaf fronts the ICC APIs on this box (prod :80, dev :81). SG
# references don't work cross-account/cross-VPC over TGW, so — same pattern as
# the `webapps` leaf — allow the perimeter ingress VPC's CIDR rather than the
# ALB's security group. Toggle with var.enable_icc_alb_ingress.
###############################################################################

locals {
  icc_alb_ingress_rules = var.enable_icc_alb_ingress ? [
    for p in var.icc_alb_ports : {
      from_port   = p
      to_port     = p
      protocol    = "tcp"
      cidr_blocks = [var.perimeter_ingress_vpc_cidr]
      description = "ICC API port ${p} from perimeter crm-alb"
    }
  ] : []
}

module "ec2" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = data.aws_ssm_parameter.ubuntu_2204_amd64.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip

  iam_instance_profile = aws_iam_instance_profile.this.name
  key_name             = var.key_name

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

  ingress_rules = local.icc_alb_ingress_rules

  root_volume_size = var.root_volume_size_gib
  root_volume_type = "gp3"

  imdsv2_required         = true
  monitoring              = false
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role        = "insight-ubuntu"
    Environment = "dev"
  }
}

resource "aws_vpc_security_group_ingress_rule" "eice_ssh" {
  count = var.eice_security_group_id == "" ? 0 : 1

  security_group_id            = module.ec2.security_group_id
  referenced_security_group_id = var.eice_security_group_id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "Admin SSH from EC2 Instance Connect Endpoint"
}

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

# NB: no `ami_id_used` output. `aws_ssm_parameter.value` is marked sensitive
# by the AWS provider, so exporting it via a root-module output requires
# `sensitive = true` and only shows as "(sensitive value)" in the plan.
# The AMI ID appears in the plan on the instance itself and in
# `aws ec2 describe-instances` after apply, which is enough.
