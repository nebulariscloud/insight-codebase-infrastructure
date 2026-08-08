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

variable "enable_liveness_alarm" {
  description = <<-EOT
    Create the per-Web-ACL "no-metrics" dead-man's-switch alarm.

    Every threshold alarm in this module uses treat_missing_data =
    "notBreaching", so a misconfigured alarm looks identical to a healthy one.
    This alarm inverts that (AllowedRequests < 1, missing data = breaching) and
    fires when a Web ACL publishes nothing at all — which is what catches
    wrong namespaces/dimensions, a detached Web ACL, or a dead backend.

    Leave on for anything internet-facing. Turn off only for Web ACLs in front
    of resources with legitimately bursty or zero overnight traffic, where it
    would flap.
  EOT
  type        = bool
  default     = true
}

variable "liveness_evaluation_periods" {
  description = <<-EOT
    Consecutive 1-HOUR periods with no AllowedRequests datapoint before the
    liveness alarm fires. Default 3 = three hours of total silence.

    The period is one hour, not five minutes, because WAF only publishes a
    metric datapoint when the value is nonzero (AWS WAF core metrics:
    "Reporting criteria: There is a nonzero value"). On a low-traffic resource
    most 5-minute windows are legitimately empty — scriptcase-lb measured 20
    requests in 3 hours on 2026-08-06 — so a short period would flap.

    Raise this for resources with genuinely quiet overnight windows. If a
    resource can go a full working day with no traffic, set
    enable_liveness_alarm = false for it instead.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.liveness_evaluation_periods >= 2
    error_message = "Use at least 2 periods (2 hours) or the alarm will flap on normal quiet spells."
  }
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
