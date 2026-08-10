variable "account_name" {
  description = "Spoke account label."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Perimeter spoke."
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

variable "web_acl_names" {
  description = <<-EOT
    Names of every REGIONAL Web ACL in this account that should log to the
    bucket this leaf creates. One aws_wafv2_web_acl_logging_configuration is
    created per name. Ownership of the Web ACL itself is irrelevant here -
    CFN-managed (LZA) and Terraform-managed Web ACLs are both fine, because
    the logging configuration is a separate AWS resource.

    Keep this list in sync with the Web ACLs that actually exist. A Web ACL
    absent from this list silently gets no logging - that is exactly how
    crm-alb-waf and osticket-alb-waf went unlogged after they were created.
    The cross-check is `waf-finish-checklist.md` step 6.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.web_acl_names) > 0
    error_message = "web_acl_names must list at least one Web ACL."
  }
}

variable "log_retention_days" {
  description = "Days before WAF log objects expire. 365 mirrors the LZA central log bucket retention."
  type        = number
  default     = 365
}
