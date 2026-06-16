###############################################################################
# Inputs to the security-baseline module.
#
# Naming convention:
#   - `regions` is an object keyed by provider alias, not a list, so the module
#     can statically wire each region setting to its provider alias.
#   - Account-level resources do not need a region alias; they use the default
#     provider supplied by the consuming leaf.
###############################################################################

variable "account_name" {
  description = "Spoke account name (used in tags and IAM session names). Free-form label."
  type        = string
}

variable "regions" {
  description = "Map of provider alias to AWS region name. Keys must match the configuration_aliases declared in versions.tf."
  type = object({
    use1 = string
    use2 = string
    usw2 = string
  })
  default = {
    use1 = "us-east-1"
    use2 = "us-east-2"
    usw2 = "us-west-2"
  }
}

###############################################################################
# Account.1 - SECURITY alternate contact
###############################################################################

variable "security_contact_name" {
  description = "Name shown to AWS for the SECURITY alternate contact."
  type        = string
}

variable "security_contact_email" {
  description = "Email AWS uses for security incident notifications."
  type        = string
}

variable "security_contact_phone" {
  description = "Phone AWS uses for security incident notifications. Sourced from SSM SecureString in the leaf - never declared as a literal in source."
  type        = string
  sensitive   = true
}

variable "security_contact_title" {
  description = "Title shown to AWS for the SECURITY alternate contact."
  type        = string
}

###############################################################################
# SSM.6 - SSM Automation CloudWatch logging
###############################################################################

variable "automation_log_retention_days" {
  description = "CloudWatch log retention (days) for /aws/ssm/automation in each active region. Matches the LZA cloudwatchLogRetentionInDays default."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.automation_log_retention_days)
    error_message = "automation_log_retention_days must be one of the values supported by CloudWatch Logs."
  }
}

variable "automation_log_kms_deletion_window" {
  description = "Pending-deletion window (days) for the SSM Automation CMK in each region. Defaults to the AWS minimum that still allows recovery."
  type        = number
  default     = 30

  validation {
    condition     = var.automation_log_kms_deletion_window >= 7 && var.automation_log_kms_deletion_window <= 30
    error_message = "automation_log_kms_deletion_window must be between 7 and 30 days."
  }
}

###############################################################################
# Inspector - feature-flagged. Off by default until decision item D-1 lands.
###############################################################################

variable "inspector_enabled" {
  description = "Master toggle for Inspector v2 enablement. Leave false until D-1 is resolved."
  type        = bool
  default     = false
}

variable "inspector_resource_types" {
  description = "Resource types to enable Inspector v2 for. Subset of EC2, ECR, LAMBDA, LAMBDA_CODE."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for t in var.inspector_resource_types : contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE"], t)
    ])
    error_message = "inspector_resource_types may only contain EC2, ECR, LAMBDA, or LAMBDA_CODE."
  }
}

variable "inspector_regions" {
  description = "Region names where Inspector v2 should be enabled. Each value must match one of the regions in var.regions."
  type        = list(string)
  default     = []
}

###############################################################################
# Tagging
###############################################################################

variable "tags" {
  description = "Extra tags merged on top of the module's default tags."
  type        = map(string)
  default     = {}
}
