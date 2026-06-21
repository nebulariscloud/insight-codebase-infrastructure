variable "name" {
  description = "Logical name for the monitoring stack. Used as a prefix on alarm + topic names + the dashboard."
  type        = string
}

variable "web_acls" {
  description = <<-EOT
    Web ACLs to monitor. Map keyed by short id (used in resource names).

    Each entry:
      name   - WebACL name (= the CloudWatch metric name dimension)
      scope  - "REGIONAL" or "CLOUDFRONT"
      region - region to query metrics from. For CLOUDFRONT this MUST be us-east-1.
  EOT
  type = map(object({
    name   = string
    scope  = string
    region = string
  }))
}

variable "blocked_requests_threshold" {
  description = <<-EOT
    BlockedRequests / 5min threshold that fires a Medium alarm. Tune to your
    traffic baseline. Default is intentionally generous so the alarm doesn't
    chirp under normal scanner noise.
  EOT
  type        = number
  default     = 1000
}

variable "rate_limit_block_threshold" {
  description = "BlockedRequests under the RateLimit rule / 5min that fires a High alarm. A spike here means a sustained source is hitting the cap."
  type        = number
  default     = 200
}

variable "common_rule_set_block_threshold" {
  description = "BlockedRequests under AWS-CommonRuleSet / 5min that fires a Medium alarm. Sudden spike usually means a new attack pattern or a bad deploy producing payloads that look hostile."
  type        = number
  default     = 500
}

variable "evaluation_periods" {
  description = "Number of consecutive 5-minute periods above threshold before alarm fires."
  type        = number
  default     = 2
}

variable "sns_email_high" {
  description = "Email subscribed to the High-severity topic. Pre-filled from replacements-config.yaml SecurityHigh."
  type        = string
}

variable "sns_email_medium" {
  description = "Email subscribed to the Medium-severity topic."
  type        = string
}

variable "sns_email_low" {
  description = "Email subscribed to the Low-severity topic. Used for daily summary / informational alarms."
  type        = string
  default     = ""
}

variable "create_dashboard" {
  description = "Build a CloudWatch dashboard with one row per Web ACL plus a rollup."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
