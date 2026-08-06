variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Production spoke."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "stack_name" {
  description = "Short stack name."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Restore source
# ----------------------------------------------------------------------------

variable "snapshot_identifier" {
  description = <<-EOT
    RDS snapshot to restore this instance FROM. This is the manual snapshot of
    the source iccmaindb, shared cross-account from the source tenant and
    copied+re-encrypted into this account/region with the LZA RDS key (see
    README, "Pre-cutover replication setup"). Empty on the very first plan is
    invalid — the destination DB is a restore, not a fresh create, so that the
    data + binlog position line up for replication.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(rds:)?[a-z0-9-]+$", var.snapshot_identifier))
    error_message = "snapshot_identifier must be an RDS snapshot identifier."
  }
}

# ----------------------------------------------------------------------------
# Instance shape (mirror the source: MySQL 5.7.44, db.t3.small, 50 GiB, MultiAZ)
# ----------------------------------------------------------------------------

variable "identifier" {
  description = "RDS instance identifier in the destination."
  type        = string
  default     = "iccmaindb"
}

variable "instance_class" {
  description = "Instance class. Source is db.t3.small."
  type        = string
  default     = "db.t3.small"
}

variable "allocated_storage_gib" {
  description = "Storage GiB. Source is 50. Restore requires >= snapshot size."
  type        = number
  default     = 50
}

variable "storage_type" {
  description = "Storage type. Source is gp2; gp3 is the better default in the destination."
  type        = string
  default     = "gp3"
}

variable "multi_az" {
  description = "MultiAZ. Source is MultiAZ=true."
  type        = bool
  default     = true
}

variable "engine_version" {
  description = <<-EOT
    MySQL engine version. Source is 5.7.44. Keep 5.7 for the migration (do the
    8.0 upgrade as a separate later exercise). When restoring from a snapshot
    RDS infers the version, so this mostly documents intent.
  EOT
  type        = string
  default     = "5.7.44"
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

variable "vpc_id" {
  description = "shared-prod VPC ID."
  type        = string
}

variable "db_subnet_ids" {
  description = "shared-prod DATA subnet IDs (data-a + data-b) for the DB subnet group."
  type        = list(string)
  validation {
    condition     = length(var.db_subnet_ids) >= 2
    error_message = "RDS needs at least two subnets in different AZs for the subnet group."
  }
}

variable "app_client_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach MySQL 3306. These are the app-tier subnets / IPs in
    shared-prod that connect to the DB (WS Aheeva, the two webapps). Private
    only — the destination DB is NOT publicly accessible (unlike the source).
  EOT
  type        = list(string)
  default     = ["10.12.0.0/16"]
}

variable "source_replication_cidrs" {
  description = <<-EOT
    Temporary: CIDRs allowed inbound on 3306 for the ONGOING binlog replication
    catch-up window, if the destination pulls from the source over a routed
    path. Usually empty (replication is destination->source outbound). Populate
    only if your replication topology needs source->destination inbound.
  EOT
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------------
# Parameter group (clone of source enabletriggers-5-7 with binlog_format=ROW)
# ----------------------------------------------------------------------------

variable "parameter_group_family" {
  description = "RDS parameter group family. MySQL 5.7 => mysql5.7."
  type        = string
  default     = "mysql5.7"
}

# ----------------------------------------------------------------------------
# Backups / protection
# ----------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Automated backup retention. Source is 7."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Preferred backup window (UTC). Source is 07:00-09:00."
  type        = string
  default     = "07:00-09:00"
}

variable "maintenance_window" {
  description = "Preferred maintenance window. Source is wed:05:30-wed:06:30."
  type        = string
  default     = "wed:05:30-wed:06:30"
}

variable "deletion_protection" {
  description = "Deletion protection. Source has it on."
  type        = bool
  default     = true
}
