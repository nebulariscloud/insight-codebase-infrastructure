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

variable "web_acls" {
  description = <<-EOT
    Web ACLs to alarm on and chart, keyed by short id, with optional per-ACL
    threshold overrides.

    Replaces the previous one-variable-per-Web-ACL shape, which stopped scaling
    at two. The KEY is baked into alarm names
    (perimeter-waf-<key>-<alarm-type>), so keys are stable identifiers —
    renaming one destroys the old alarms and their history. `ingress` and
    `scriptcase` are kept verbatim for that reason.

    Any threshold left unset falls back to the module default. They are set
    per-ACL here because measured traffic differs by roughly an order of
    magnitude between these Web ACLs — see docs/waf/waf-traffic-baseline.md.

    No ARN lookup happens in this leaf (unlike waf-logs), so a Web ACL may be
    listed before it exists; its alarms simply sit in INSUFFICIENT_DATA until
    metrics start flowing. That is why crm and osticket can be listed here
    ahead of their Web ACLs being created by PR #60.
  EOT
  type = map(object({
    name                             = string
    blocked_requests_threshold       = optional(number)
    rate_limit_block_threshold       = optional(number)
    common_rule_set_block_threshold  = optional(number)
    known_bad_inputs_block_threshold = optional(number)
  }))
  default = {
    ingress    = { name = "ingress-alb-waf" }
    scriptcase = { name = "scriptcase-lb-waf" }
  }
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
