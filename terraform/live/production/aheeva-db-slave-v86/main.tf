###############################################################################
# Aheeva DB Slave v8.6 (Production / shared-prod)
#
# Migration of `i-05b16ebe4f90c2c03` ("Aheeva DB Slave v86") from the source
# tenant (254422596287 / us-east-1, private 10.0.1.172, EIP 3.228.31.130) into
# shared-prod / us-east-2. Private box. MariaDB replica of the Aheeva CTI v8.6
# box, which is the master.
#
# CentOS 7.9.2009. MariaDB, not MySQL.
#
# WHY THE AMI PROVENANCE IS UNUSUAL --------------------------------------------
# The source instance carried AWS Marketplace product code
# `cvugziknvmxgqna9noibqnnsy` (the delisted CentOS 7 listing). A product code
# cannot be removed by any API path - copy-image, copy-snapshot and a volume
# round-trip all re-inherit it, and Production cannot even AttachVolume a
# tainted-lineage volume. The only thing that severs it is writing the bytes
# into a volume AWS created blank, because a blank volume has no lineage.
#
# So this AMI came via a block-level `dd` performed in the SOURCE tenant (the
# only account where the subscription is accepted), then snapshot -> share ->
# cross-region copy onto the LZA EBS key -> register-image. Verified
# `ProductCodes: null`. Full procedure and every intermediate ID:
#   docs/07-Operations/aheeva-v86-dd-migration-runbook.md
#
# REPLICATION ------------------------------------------------------------------
# `skip-slave-start` was added to /etc/my.cnf ON THE COPY (mounted on the dd
# helper), deliberately NOT on the production source box - see the client
# document, which commits to changing no configuration on their servers.
# It matters because STOP SLAVE does not survive a restart: without it this
# instance would auto-connect to whatever master.info names on first boot.
#
# master.info captured at image time (2026-09-16 14:08 UTC):
#   Master_Log_File = dbmaster-bin.000557
#   Master_Log_Pos  = 650520737
#   Master_Host     = 10.0.1.92   (the SOURCE master's private IP)
#   using_gtid      = 0           -> repoint with explicit file+pos, NOT
#                                    MASTER_AUTO_POSITION
#
# At cutover, repoint at the migrated master's private IP:
#   CHANGE MASTER TO MASTER_HOST='<new master private IP>',
#     MASTER_LOG_FILE='dbmaster-bin.000557', MASTER_LOG_POS=650520737;
#   START SLAVE;
#
# WARNING - server-id collision. This image carries `server-id=2`, identical to
# the still-running source slave. Do not START SLAVE here while the source slave
# is also replicating from the same master.
#
# SECURITY - the replication credential in master.info is stored in plaintext
# and is trivially weak (password == username). Rotate it at cutover.
#
# ACCESS -----------------------------------------------------------------------
# No SSM agent. Every migrated AMI in this estate has arrived without a working
# agent (cti-v7, webapps .65, osticket - three for three), and CentOS 7 has no
# supported agent package anyway. EC2 Instance Connect is also out: the
# ec2-instance-connect package ships on Amazon Linux only.
#
# Access is SSH using the `Aheeva` key pair baked into the image's
# authorized_keys, which the team holds as Aheeva.pem. That is why key_name is
# empty here.
#
# NOTE: setting key_name later FORCES INSTANCE REPLACEMENT. If a
# Production-managed key pair is wanted, create it and set it BEFORE this box is
# put into service - replacing it now is harmless, replacing it at cutover is
# not.
#
# DISK -------------------------------------------------------------------------
# Two volumes: /dev/sda1 200 GiB root, /dev/sdf 16 GiB data (essentially empty -
# 1 MiB of a 16 GiB volume, a partition table and a superblock).
#
# `additional_ebs_volumes` is deliberately NOT used. The AMI already declares
# both block device mappings, so AWS creates the second volume at launch.
# Declaring it here as well would collide at the same device name. This is the
# first multi-BDM instance in the estate, so read the first plan carefully.
#
# BACKUP - the module hardcodes root_block_device.delete_on_termination = true
# and the leaf cannot override it, which is exactly how cti-v7's root volume
# (and its sip.conf work) was lost on 2026-08-08. The compensating control is
# the BackupPlan tag below, which the LZA org backup policy selects on. This is
# the first EC2 leaf in the repo to carry it.
###############################################################################

locals {
  # Admin SSH FIRST and DB clients LAST. The module's for_each key embeds the
  # list index ("${from_port}-${to_port}-${protocol}-${idx}"), so inserting a
  # rule renumbers every rule after it and the plan shows those as
  # destroy+create - which the CI destroy guard then blocks on merge.
  # db_client_cidrs is the list expected to grow (questionnaire 3.1, then the
  # VPN client CIDRs), so it goes last and APPENDING to it is free.
  admin_ssh_rules = [
    for c in var.admin_ssh_cidrs : {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [c]
      description = "Admin SSH from ${c}"
    }
  ]

  # One rule object per CIDR: the module only honours cidr_blocks[0].
  db_rules = [
    for c in var.db_client_cidrs : {
      from_port   = var.db_port
      to_port     = var.db_port
      protocol    = "tcp"
      cidr_blocks = [c]
      description = "MariaDB ${var.db_port} from ${c}"
    }
  ]

  ingress_rules = concat(local.admin_ssh_rules, local.db_rules)

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

  # Useless today (no SSM agent on CentOS 7) but harmless, and it means the box
  # self-registers if an agent is ever installed by hand.
  iam_instance_profile = "EC2-Default-SSM-Role"

  ingress_rules = local.ingress_rules

  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  # The /dev/sdf data volume comes from the AMI's own BDM. See the header.
  additional_ebs_volumes = []

  imdsv2_required = true

  # ec2:MonitorInstances is not in the TerraformExecution allow-policy.
  monitoring = false

  ebs_optimized           = true
  disable_api_termination = true

  # No EIP on the replica. Also note allocate_eip = true is currently UNSAFE on
  # this module: associate_public_ip_address is hardcoded false, which produces a
  # permanent forced replacement (PR #93 fixes it; it destroyed cti-v7 on
  # 2026-08-08 when a modules/ change fanned an apply across every leaf).
  allocate_eip = false

  tags = {
    Role = "aheeva-db-slave-v86"

    # Selected by the LZA org backup policy (tag key BackupPlan, value Daily:
    # 05:00 UTC, cold storage after 30 days, delete after 365). Compensates for
    # the module's hardcoded root delete_on_termination = true.
    BackupPlan = "Daily"
  }
}

###############################################################################
# Outputs
###############################################################################

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. This is the address MariaDB clients connect to."
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
