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
  description = "Name of the ingress-alb Web ACL."
  type        = string
  default     = "ingress-alb-waf"
}

variable "scriptcase_web_acl_name" {
  description = "Name of the scriptcase-lb Web ACL."
  type        = string
  default     = "scriptcase-lb-waf"
}

variable "sns_email_high" {
  description = "Email subscribed to High-severity WAF alarms. Default mirrors SecurityHigh in replacements-config.yaml."
  type        = string
  default     = "insightgroup-security-high@nebulariscloud.com"
}

variable "sns_email_medium" {
  description = "Email subscribed to Medium-severity WAF alarms."
  type        = string
  default     = "insightgroup-security-medium@nebulariscloud.com"
}

variable "sns_email_low" {
  description = "Email subscribed to Low-severity WAF alarms."
  type        = string
  default     = "insightgroup-security-low@nebulariscloud.com"
}
