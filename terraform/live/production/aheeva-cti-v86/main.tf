###############################################################################
# Aheeva CTI v8.6 (Production / shared-prod) — direct-EIP SIP endpoint
#
# Migration of `i-085b1b072af56e661` ("Aheeva CTI V8.6") from the source tenant
# (254422596287 / us-east-1, private 10.0.1.92, EIP 3.217.85.105) into
# shared-prod / us-east-2. Application server AND the MariaDB master for
# `aheeva-db-slave-v86`.
#
# CentOS 7.9.2009. MariaDB, not MySQL. Aheeva install at
# /usr/local/AheevaCustomServer (Java), services aheevacti / aheeva-pbxproxy /
# aheeva-router / aheeva-msg-center / aheeva-vault.
#
# ⚠️ DO NOT APPLY UNTIL THREE THINGS LAND. See README. In short:
#     1. PR #93 merged  — the module hardcodes associate_public_ip_address =
#        false, so allocate_eip = true creates a PERMANENT FORCED REPLACEMENT.
#        That is the drift that destroyed cti-v7 on 2026-08-08 when a
#        terraform/modules/ change fanned an apply across every leaf.
#     2. SCP carve-out for tag Migrated = AheevaCTIV86 (config zip + LZA
#        pipeline run), or ec2:AllocateAddress is denied.
#     3. VPC Block Public Access exclusion for subnet-08ce7fb6c30eed107.
#
#   ⚠️ THE PLAN ON THIS PR CANNOT REVEAL PROBLEM 1. Nothing is in state yet, so
#   everything shows as a clean create. The forced replacement only becomes
#   visible on the NEXT plan after apply. Do not read a clean plan here as
#   evidence that #93 is unnecessary.
#
# WHY THIS BOX NEEDS A DIRECTLY-ATTACHED PUBLIC IP -----------------------------
# /etc/asterisk/sip.conf on the migrated disk contains, verbatim:
#     externip=3.217.85.105
#     localnet=10.0.1.0/255.255.255.0
# The box advertises its own public address in SIP/SDP, and RTP media terminates
# directly on it with no SBC. It therefore cannot sit behind NAT or an NLB the
# way the SFTP and webapp migrations do. Same conclusion cti-v7 reached, for the
# same reasons, documented in docs/07-Operations/cti-v7-migration-options.md.
#
# Both values must be rewritten in-box at cutover: externip to the new EIP,
# localnet to the destination subnet.
#
# LICENSING --------------------------------------------------------------------
# Unlike cti-v7, this box is NOT host-fingerprint licensed. It performs an
# IP-based round-trip handshake with Aheeva's own licence server; there is no
# local .lic file and no local RLM server. Consequence: Aheeva must allowlist
# the new EIP (TCP 5053 and 50555) before cutover — the same vendor ask cti-v7
# made, but with no reissue required.
#
# Because the EIP is directly attached, this instance's OUTBOUND source address
# is the EIP rather than the egress NAT gateways. One address therefore serves
# both inbound SIP and the outbound licence check.
#
# ⚠️ Do NOT lock this instance's egress. An earlier draft of the migration plan
# proposed no-internet-egress as a safety belt; that would break the licence
# handshake. The DB slave can be locked down, this box cannot.
#
# WHY THE AMI PROVENANCE IS UNUSUAL --------------------------------------------
# The source carried AWS Marketplace product code cvugziknvmxgqna9noibqnnsy —
# the delisted CentOS 7 listing. No API path strips a product code; only writing
# the bytes into a volume AWS created blank severs the lineage. This AMI came
# via a block-level dd in the SOURCE tenant, then share → cross-region copy onto
# the LZA EBS key → register-image. Verified ProductCodes: null.
# Full procedure: docs/07-Operations/aheeva-v86-dd-migration-runbook.md
#
# DISK -------------------------------------------------------------------------
# Two volumes: /dev/sda1 185 GiB root, /dev/sdb 8 GiB data.
# additional_ebs_volumes is deliberately EMPTY — the AMI declares both BDMs and
# AWS creates the second volume at launch. Proven on the DB slave
# (i-034a56060c27f95fb), where /dev/sdf attached exactly this way.
#
# BACKUP - the module hardcodes root_block_device.delete_on_termination = true
# and the leaf cannot override it. That is how cti-v7's root volume, and the
# sip.conf externip edit on it, were lost on 2026-08-08. BackupPlan = Daily
# below is the compensating control.
###############################################################################

locals {
  # Scoped SCP exception keys on this exact tag value for BOTH
  # ec2:AllocateAddress (aws:RequestTag) and ec2:AssociateAddress
  # (aws:ResourceTag). It MUST match lza-core-workloads-guardrails-1.json.
  #
  # Deliberately NOT "CTIv7" — the cti-v7 leaf warns against reusing its value,
  # because a second instance carrying it would silently widen that exception.
  migration_tag = "AheevaCTIV86"

  # Rule order matters. The module keys security-group rules by LIST INDEX
  # ("${from_port}-${to_port}-${protocol}-${idx}"), so anything that shifts an
  # index becomes a destroy+create that the CI destroy guard blocks on merge.
  #
  # Ordered fixed-length first, then the lists in the order they will settle:
  #   admin  - fixed, 2 rules, never changes
  #   sip    - EMPTY today, populated ONCE when the client returns the peer list
  #   rtp    - derived from sip, same one-time change
  #   db     - the list expected to grow, so it goes LAST and appending is free
  #
  # Populating sip_peer_cidrs is therefore a one-time renumber of the rtp and db
  # rules. Do it BEFORE this box carries traffic, when recreating an SG rule
  # costs nothing, and authorise it with an ALLOW-DESTROY line.

  admin_rules = [
    for p in var.admin_ports : {
      from_port   = p
      to_port     = p
      protocol    = "tcp"
      cidr_blocks = [var.admin_ingress_cidr]
      description = "Aheeva admin GUI ${p} from perimeter ingress ALB"
    }
  ]

  # SIP signalling. UDP only, matching cti-v7 and standard IP-authenticated
  # trunking. The SOURCE security group also had TCP 5060 open; if a carrier
  # turns out to need it, add it here and expect the renumber.
  sip_rules = [
    for c in var.sip_peer_cidrs : {
      from_port   = 5060
      to_port     = 5060
      protocol    = "udp"
      cidr_blocks = [c]
      description = "SIP UDP 5060 from peer ${c}"
    }
  ]

  rtp_cidrs = concat(var.sip_peer_cidrs, var.rtp_extra_cidrs)

  rtp_rules = [
    for c in local.rtp_cidrs : {
      from_port   = var.rtp_from_port
      to_port     = var.rtp_to_port
      protocol    = "udp"
      cidr_blocks = [c]
      description = "RTP media ${var.rtp_from_port}-${var.rtp_to_port} from ${c}"
    }
  ]

  # MariaDB. This box is the MASTER, so replication arrives INBOUND from the
  # replica - 10.12.1.54 must be allowed or replication cannot be established.
  db_rules = [
    for c in var.db_client_cidrs : {
      from_port   = var.db_port
      to_port     = var.db_port
      protocol    = "tcp"
      cidr_blocks = [c]
      description = "MariaDB ${var.db_port} from ${c}"
    }
  ]

  ingress_rules = concat(
    local.admin_rules,
    local.sip_rules,
    local.rtp_rules,
    local.db_rules,
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
  subnet_id     = var.public_subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip
  key_name      = var.key_name

  # The whole point of this shape. Gated on the SCP carve-out AND on PR #93.
  allocate_eip = true

  # Useless today (no SSM agent on CentOS 7, no supported package) but harmless.
  iam_instance_profile = "EC2-Default-SSM-Role"

  ingress_rules = local.ingress_rules

  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  # /dev/sdb comes from the AMI's own BDM. See the header.
  additional_ebs_volumes = []

  imdsv2_required = true

  # ec2:MonitorInstances is not in the TerraformExecution allow-policy.
  monitoring = false

  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role = "aheeva-cti-v86"

    # Keys the scoped SCP exception. Must match the SCP exactly.
    Migrated = local.migration_tag

    # Selected by the LZA org backup policy. Compensates for the module's
    # hardcoded root delete_on_termination = true.
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
  description = "Private IP. This is the MASTER_HOST the DB slave repoints to at cutover."
  value       = module.ec2_migrated.private_ip
}

output "public_ip" {
  description = "Elastic IP. Give this to Aheeva for the licence allowlist and to every SIP peer."
  value       = module.ec2_migrated.public_ip
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}

output "availability_zone" {
  description = "AZ the instance landed in."
  value       = module.ec2_migrated.availability_zone
}
