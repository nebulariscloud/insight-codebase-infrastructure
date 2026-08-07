###############################################################################
# osTicket (Production / shared-prod)
#
# Migration of the Lightsail instance `osticket1` from the source tenant
# (254422596287 / us-east-1, static IP 204.236.253.33) into shared-prod /
# us-east-2. Private box on Apache 80, fronted by an ALB in Perimeter which
# registers this instance's private IP as an IP target over the TGW.
#
# Lightsail specifics worth knowing:
#   * Lightsail static IPs do NOT transfer to EC2. Anything that allowlisted
#     204.236.253.33 inbound must move to the ALB; anything allowlisting it for
#     OUTBOUND (mail relays, partner APIs) must move to the egress NAT EIPs
#     3.151.88.5 / 3.133.15.33. See lightsail-migration-guide.md step 9.
#   * The exported AMI keeps the Lightsail blueprint's users/services and
#     cloud-init config. Post-launch cleanup happens inside the OS, not here.
#
# The source AMI was encrypted with the AWS-managed `aws/ebs` key, which cannot
# be shared cross-account, so it went through the transfer-CMK dance (see the
# ami_id comment in terraform.tfvars). No marketplace product code, so none of
# the dd work that CTI v7 needed.
#
# DATABASE: osTicket is a client of iccmaindb (it was 204.236.253.33 in the
# source RDS 3306 allowlist). It must keep pointing at the SOURCE database
# (iccmaindb.cqmvz00gvdb5.us-east-1.rds.amazonaws.com) until the DB cutover —
# the destination is currently a READ-ONLY replica and writes would be rejected
# (and, if read_only were off, would diverge the replica). Its credentials live
# in osTicket's include/ost-config.php. No DB config change in this leaf.
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
    Role = "osticket"
  }
}

# Optional EICE admin SSH (TCP 22 from the EICE SG) when var.eice_security_group_id is set.
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
# Outputs — the perimeter ALB leaf reads private_ip and registers it as a target.
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
