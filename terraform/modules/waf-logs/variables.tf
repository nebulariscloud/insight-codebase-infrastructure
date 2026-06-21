variable "name" {
  description = <<-EOT
    Logical name for the logging stack. Used as a tag/Name and to derive
    KMS alias. The bucket name itself is built from var.bucket_name (which
    must start with 'aws-waf-logs-').
  EOT
  type        = string
}

variable "bucket_name" {
  description = <<-EOT
    Exact S3 bucket name to create. AWS WAF requires the bucket name to
    start with 'aws-waf-logs-'. Recommended pattern:
      aws-waf-logs-<account-id>-<region>
  EOT
  type        = string
  validation {
    condition     = can(regex("^aws-waf-logs-", var.bucket_name))
    error_message = "bucket_name must start with 'aws-waf-logs-' (WAF requirement)."
  }
}

variable "log_retention_days" {
  description = <<-EOT
    Days before WAF log objects expire. 365 mirrors the LZA central log
    bucket retention. Set to 0 to disable lifecycle (not recommended).
  EOT
  type        = number
  default     = 365
}

variable "transition_to_glacier_ir_days" {
  description = "Days after which objects transition to GLACIER_IR. 30 keeps recent logs hot for queries, archives the rest."
  type        = number
  default     = 30
}

variable "kms_deletion_window_in_days" {
  description = "KMS key deletion window. 30 = AWS maximum, gives ample recovery time."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}

###############################################################################
# Optional: attach this logging destination to existing Web ACLs.
#
# When attach_to_web_acl_arns is non-empty, the module creates one
# aws_wafv2_web_acl_logging_configuration per ARN. Use this to enable logging
# on the CFN-managed Web ACLs (ingress-alb-waf, scriptcase-lb-waf) without
# mutating the underlying Web ACL itself - the LoggingConfiguration is a
# separate AWS resource.
###############################################################################

variable "attach_to_web_acl_arns" {
  description = <<-EOT
    Web ACL ARNs to enable logging on. The bucket created by this module is
    used as the destination. Empty = build the bucket, attach nothing
    (caller may attach via a separate aws_wafv2_web_acl_logging_configuration).
  EOT
  type        = list(string)
  default     = []
}

variable "redacted_headers" {
  description = "Headers to redact from WAF logs. Defaults match the waf-managed module."
  type        = list(string)
  default     = ["authorization", "cookie"]
}
