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
  default     = "amex-recordings"
}

variable "region" {
  description = "AWS region the bucket lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Bucket configuration
# ----------------------------------------------------------------------------

variable "bucket_name" {
  description = <<-EOT
    Globally-unique S3 bucket name. Defaults to
    "amex-recordings-prod-<account_id>" so it's unique to whoever applies.
    Override only if you've already reserved a name elsewhere.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.bucket_name == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase letters/digits/hyphens/dots."
  }
}

variable "enable_default_object_lock_retention" {
  description = <<-EOT
    When true, every uploaded object gets a default Object Lock retention
    applied automatically. Leave false to opt in per-object via the
    PutObject API (most common pattern for recordings).
  EOT
  type        = bool
  default     = false
}

variable "default_object_lock_mode" {
  description = "GOVERNANCE (admins can override with s3:BypassGovernanceRetention) or COMPLIANCE (no one can shorten or delete until expiry, including root)."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.default_object_lock_mode)
    error_message = "default_object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "default_object_lock_days" {
  description = "Default Object Lock retention period in days. Only used when enable_default_object_lock_retention is true."
  type        = number
  default     = 365
}

variable "noncurrent_version_retention_days" {
  description = "How many days to keep non-current (overwritten) object versions before lifecycle expires them. Set to 0 to keep forever."
  type        = number
  default     = 365
}
