variable "name" {
  description = "Logical name for the monitoring stack. Used as a prefix on alarm + topic names + the dashboard."
  type        = string
}

variable "web_acls" {
  description = <<-EOT
    Web ACLs to monitor. Map keyed by short id, which is baked into alarm names
    (<name>-<key>-<alarm-type>) so keys are stable identifiers — renaming one
    destroys the old alarms and their history.

    Each entry:
      name   - WebACL name (= the CloudWatch WebACL dimension value)
      scope  - "REGIONAL" or "CLOUDFRONT"
      region - region to query metrics from. For CLOUDFRONT this MUST be us-east-1.

    Optional per-Web-ACL threshold overrides. Any left null fall back to the
    module-level defaults below.

    WHY PER-WEB-ACL: measured 2026-08-08 over 4 days, peak BlockedRequests per
    5-minute window differed by ~8x between two Web ACLs on the same account —
    ingress-alb-waf 2464, scriptcase-lb-waf 297. A single global threshold
    cannot serve both: anything suited to ingress leaves scriptcase effectively
    unmonitored, and anything suited to scriptcase makes ingress alarm on
    routine scanner traffic.
  EOT
  type = map(object({
    name   = string
    scope  = string
    region = string

    blocked_requests_threshold       = optional(number)
    rate_limit_block_threshold       = optional(number)
    common_rule_set_block_threshold  = optional(number)
    known_bad_inputs_block_threshold = optional(number)
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
  description = <<-EOT
    Default BlockedRequests under AWS-CommonRuleSet / 5min that fires a Medium
    alarm. A spike here usually means a new attack pattern or a bad deploy
    producing payloads that look hostile.

    This is the most actionable of the alarms. Unlike total BlockedRequests
    (which is dominated by IP-reputation scanner noise), CommonRuleSet firing
    means somebody is probing the application itself with OWASP-style payloads.
  EOT
  type        = number
  default     = 500
}

variable "known_bad_inputs_block_threshold" {
  description = <<-EOT
    Default BlockedRequests under AWS-KnownBadInputs / 5min that fires a Medium
    alarm.

    Like CommonRuleSet, this is a targeted-probing signal rather than background
    noise — it catches known exploit payloads against common CVEs. Measured
    peaks 2026-08-08: ingress-alb-waf 387, scriptcase-lb-waf 107.
  EOT
  type        = number
  default     = 600
}

variable "enable_known_bad_inputs_alarm" {
  description = <<-EOT
    Create the per-Web-ACL AWS-KnownBadInputs alarm. On by default.

    Off only makes sense for a Web ACL that does not attach the
    AWSManagedRulesKnownBadInputsRuleSet rule group at all — the metric would
    never publish and the alarm would sit in INSUFFICIENT_DATA forever.
  EOT
  type        = bool
  default     = true
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
