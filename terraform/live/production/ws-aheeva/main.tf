###############################################################################
# WS Aheeva (Production / shared-prod) — Wave 2
#
# Lift-and-shift of the WS Aheeva file-loader from the source tenant
# (254422596287 / us-east-1, i-025bede8c30dbcece, 172.30.2.200) into
# shared-prod / us-east-2. This is the box clients drop daily files onto over
# FTPS; it processes them and writes into the RDS (iccmaindb).
#
# Disk is mutable (the file inbox changes), so the FINAL AMI is taken at
# cutover (after draining the inbound queue), not from a stale baseline.
#
# Source root volume is 80 GiB, encrypted with aws/ebs (AWS-managed,
# unshareable) — the AMI is produced via the transfer-CMK re-encrypt dance
# (see README), same as webapps-php73.
#
# Cutover ordering: WS Aheeva cuts over WITH the RDS (Wave 2). After the RDS
# is promoted, WS Aheeva's DB connection string is pointed at the new
# iccmaindb endpoint (config edit inside the box, over SSH/SSM).
###############################################################################

locals {
  # FTPS control + passive range, from the perimeter ingress NLB CIDR (the NLB
  # SNATs, so the box sees NLB private IPs). Client-IP allowlisting is enforced
  # at the NLB SG layer in the sibling perimeter/ws-aheeva-ftps-nlb leaf.
  ftps_rules = [
    {
      from_port   = var.ftps_control_port
      to_port     = var.ftps_control_port
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "FTPS control ${var.ftps_control_port} from ingress NLB"
    },
    {
      from_port   = var.ftps_passive_from
      to_port     = var.ftps_passive_to
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "FTPS passive ${var.ftps_passive_from}-${var.ftps_passive_to} from ingress NLB"
    },
  ]

  # Extra Aheeva app/admin ports, scoped to admin CIDRs (cartesian of ports x cidrs).
  extra_rules = flatten([
    for p in var.extra_app_ports : [
      for c in var.extra_app_cidrs : {
        from_port   = p
        to_port     = p
        protocol    = "tcp"
        cidr_blocks = [c]
        description = "Aheeva app/admin ${p} from ${c}"
      }
    ]
  ])

  ingress_rules   = concat(local.ftps_rules, local.extra_rules)
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
    Role = "ws-aheeva"
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
# Outputs — the perimeter FTPS NLB leaf reads private_ip and targets it.
###############################################################################

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Target this from the perimeter FTPS NLB."
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
