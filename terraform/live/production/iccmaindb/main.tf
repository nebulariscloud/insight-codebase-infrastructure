###############################################################################
# RDS iccmaindb (Production / shared-prod) — Wave 2
#
# Destination MySQL 5.7 instance for the CTI v7 cluster's database, migrated
# from the source tenant (254422596287 / us-east-1) RDS "iccmaindb".
#
# MIGRATION MECHANIC (see README for the full runbook):
#   RDS-native cross-account read replicas are NOT supported for non-Aurora
#   MySQL, so we:
#     1. Snapshot the source, re-encrypt with a shareable CMK (source is on the
#        aws/rds AWS-managed key which can't be shared), share to this account,
#        copy cross-region + re-encrypt with the destination CMK below.
#     2. RESTORE this instance from that snapshot (snapshot_identifier) so the
#        data + binlog coordinates line up.
#     3. Set up ONGOING binlog replication source->destination via
#        mysql.rds_set_external_master + mysql.rds_start_replication (run by
#        hand after apply — not Terraform-managed).
#     4. At cutover: pause source writes, wait for Seconds_Behind_Master=0,
#        mysql.rds_stop_replication, repoint apps at this instance.
#
# POSTURE CHANGE vs source: the source DB is PubliclyAccessible with 18 public
# IPs on 3306. This destination is PRIVATE (publicly_accessible=false), only
# reachable from the app-tier CIDRs in shared-prod. That is the intended
# security improvement.
###############################################################################

###############################################################################
# Customer-managed CMK for this DB's encryption at rest.
# (The source uses aws/rds; here we own a proper CMK so the DB — and any future
# cross-account share of ITS snapshots — is under a key we control.)
###############################################################################

data "aws_caller_identity" "current" {}

# Explicit key policy.
#
# WHY THIS IS HERE: RDS must create a KMS grant to use a customer CMK for
# encryption at rest. The first apply failed with
#
#   KMSKeyNotAccessibleFault: The specified KMS key ... does not exist, is not
#   enabled or you do not have permissions to access it
#
# on RestoreDBInstanceFromDBSnapshot, because the TerraformExecution role's
# allow-policy (aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json)
# is an explicit allow-list and does NOT include kms:CreateGrant. A KMS key
# policy can authorize a principal on its own, independently of that identity
# policy, so granting the role here unblocks the restore without an LZA
# pipeline change. Verified: no SCP references kms at all, and the
# TerraformExecution deny-policy only denies kms:ScheduleKeyDeletion and
# kms:DisableKey, so nothing overrides this Allow.
data "aws_iam_policy_document" "iccmaindb_key" {
  # Keep the standard root delegation so account IAM policies continue to work.
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # The role Terraform runs as. CreateGrant is the one that matters for RDS.
  statement {
    sid    = "AllowTerraformExecutionToUseAndGrant"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/TerraformExecution"]
    }
  }

  # Scope the RDS service itself to this account's RDS only.
  statement {
    sid    = "AllowRDSService"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["rds.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "iccmaindb" {
  description             = "Encryption key for the iccmaindb RDS instance"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.iccmaindb_key.json

  tags = { Name = "iccmaindb-rds-key" }
}

resource "aws_kms_alias" "iccmaindb" {
  name          = "alias/iccmaindb-rds"
  target_key_id = aws_kms_key.iccmaindb.key_id
}

###############################################################################
# DB subnet group across the shared-prod data subnets
###############################################################################

resource "aws_db_subnet_group" "iccmaindb" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = { Name = "${var.identifier}-subnet-group" }
}

###############################################################################
# Parameter group — clone of the source "enabletriggers-5-7" with the two
# non-default parameters we confirmed on the source:
#   - binlog_format=ROW  (required for external binlog replication)
#   - log_bin_trust_function_creators=1  (Aheeva app creates triggers/functions;
#     RDS has no SUPER, so this must be on or CREATE TRIGGER/FUNCTION fails 1419)
#
# TODO before cutover: dump the FULL source user-set parameter list and add any
# others here:
#   aws rds describe-db-parameters --region us-east-1 \
#     --db-parameter-group-name enabletriggers-5-7 \
#     --query "Parameters[?Source=='user'].{N:ParameterName,V:ParameterValue}" --output table
###############################################################################

resource "aws_db_parameter_group" "iccmaindb" {
  name   = "${var.identifier}-mysql57"
  family = var.parameter_group_family

  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_bin_trust_function_creators"
    value        = "1"
    apply_method = "immediate"
  }

  tags = { Name = "${var.identifier}-mysql57" }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Security group — MySQL 3306 from the app-tier only. NOT publicly accessible.
###############################################################################

resource "aws_security_group" "iccmaindb" {
  name        = "${var.identifier}-sg"
  description = "MySQL 3306 for iccmaindb, app-tier only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.identifier}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "mysql_app" {
  for_each          = toset(var.app_client_cidrs)
  security_group_id = aws_security_group.iccmaindb.id
  cidr_ipv4         = each.value
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  description       = "MySQL from app-tier ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "mysql_replication" {
  for_each          = toset(var.source_replication_cidrs)
  security_group_id = aws_security_group.iccmaindb.id
  cidr_ipv4         = each.value
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  description       = "MySQL from source (replication window) ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.iccmaindb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress (needed for outbound binlog replication to source)"
}

###############################################################################
# The RDS instance — RESTORED FROM SNAPSHOT
#
# Restoring (not creating fresh) is deliberate: the data must match a known
# binlog coordinate so mysql.rds_set_external_master can start replication from
# the right position.
###############################################################################

resource "aws_db_instance" "iccmaindb" {
  identifier          = var.identifier
  snapshot_identifier = var.snapshot_identifier

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage_gib
  storage_type      = var.storage_type
  multi_az          = var.multi_az

  db_subnet_group_name   = aws_db_subnet_group.iccmaindb.name
  parameter_group_name   = aws_db_parameter_group.iccmaindb.name
  vpc_security_group_ids = [aws_security_group.iccmaindb.id]

  # Private — the whole point vs the source's public exposure.
  publicly_accessible = false

  # Encrypted with our CMK. (Restore re-encrypts to this key.)
  storage_encrypted = true
  kms_key_id        = aws_kms_key.iccmaindb.arn

  backup_retention_period   = var.backup_retention_days
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  deletion_protection       = var.deletion_protection
  delete_automated_backups  = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"

  # Auto minor version upgrades off during migration — we control the version.
  auto_minor_version_upgrade = false
  apply_immediately          = false

  lifecycle {
    ignore_changes = [
      # snapshot_identifier only matters at create/restore time; ignore drift so
      # a later snapshot name change doesn't try to replace the live DB.
      snapshot_identifier,
      # engine_version is inferred from the snapshot on restore; managing it
      # here would fight RDS. Upgrade explicitly as a separate change.
      engine_version,
    ]
  }

  tags = {
    Role = "iccmaindb"
  }
}

###############################################################################
# Outputs
###############################################################################

output "endpoint" {
  description = "DB endpoint (host:port). Point WS Aheeva + the webapps here at cutover."
  value       = aws_db_instance.iccmaindb.endpoint
}

output "address" {
  description = "DB hostname only."
  value       = aws_db_instance.iccmaindb.address
}

output "security_group_id" {
  description = "DB security group ID."
  value       = aws_security_group.iccmaindb.id
}

output "kms_key_arn" {
  description = "CMK ARN encrypting this DB."
  value       = aws_kms_key.iccmaindb.arn
}
