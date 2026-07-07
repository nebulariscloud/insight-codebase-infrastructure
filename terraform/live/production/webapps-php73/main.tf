###############################################################################
# Webapps PHP 7.3 (Production / shared-prod) — Wave 1
#
# Lift-and-shift of "webapps php7.3" from the source tenant
# (254422596287 / us-east-1, i-02a7982851dd09a0b, 172.30.2.118) into
# shared-prod / us-east-2. Private box, HTTP 80 + HTTPS 443, fronted by the
# perimeter ingress ALB. Paired with the webapps server (shared source SGs).
#
# Standard clean migration (no marketplace product code on the source AMI).
# Source root volume is 40 GiB gp2 ENCRYPTED with a customer CMK — the CMK is
# shared to Production so the cross-account copy can read it, then the copy is
# re-encrypted with the LZA EBS key (see README).
#
# During Wave 1 this box still reaches the SOURCE RDS over egress; DB cutover
# is Wave 2. No DB config change in this leaf.
###############################################################################

locals {
  ingress_rules = [
    for p in var.app_ports : {
      from_port   = p
      to_port     = p
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "App port ${p} from perimeter ingress ALB"
    }
  ]

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

  imdsv2_required         = true
  monitoring              = false # ec2:MonitorInstances not in the TF allow-policy
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role = "webapps-php73"
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
  description = "Private IP. Register this as an IP target on the perimeter ingress ALB."
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
