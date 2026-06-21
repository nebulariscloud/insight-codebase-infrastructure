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

variable "ingress_web_acl_name" {
  description = "Name of the LZA-managed Web ACL fronting the IngressALB. Used to look up the ARN."
  type        = string
  default     = "ingress-alb-waf"
}

variable "scriptcase_web_acl_name" {
  description = "Name of the LZA-managed Web ACL fronting the Scriptcase ALB."
  type        = string
  default     = "scriptcase-lb-waf"
}

variable "log_retention_days" {
  description = "Days before WAF log objects expire. 365 mirrors the LZA central log bucket retention."
  type        = number
  default     = 365
}
