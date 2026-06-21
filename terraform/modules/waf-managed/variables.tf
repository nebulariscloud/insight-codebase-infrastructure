variable "name" {
  description = "Web ACL name. Becomes the metric name as well."
  type        = string
}

variable "scope" {
  description = "REGIONAL for ALB/API Gateway/AppSync. CLOUDFRONT only for CF (must run in us-east-1)."
  type        = string
  default     = "REGIONAL"
  validation {
    condition     = contains(["REGIONAL", "CLOUDFRONT"], var.scope)
    error_message = "scope must be REGIONAL or CLOUDFRONT."
  }
}

variable "rate_limit" {
  description = "Requests per 5 minutes per IP before blocking. AWS default rule limit is 100-20,000,000."
  type        = number
  default     = 2000
}

variable "common_rule_overrides_to_count" {
  description = <<-EOT
    AWSManagedRulesCommonRuleSet sub-rules to set to Count instead of Block.
    Common false-positives: SizeRestrictions_BODY (large request bodies),
    GenericRFI_BODY/QUERYARGUMENTS (URL-like params), EC2MetaDataSSRF_BODY
    (apps that legitimately send 169.254.169.254 in payloads).
  EOT
  type        = list(string)
  default = [
    "EC2MetaDataSSRF_BODY",
    "SizeRestrictions_BODY",
    "GenericRFI_BODY",
    "GenericRFI_QUERYARGUMENTS",
  ]
}

variable "enable_known_bad_inputs" {
  description = "Attach AWSManagedRulesKnownBadInputsRuleSet."
  type        = bool
  default     = true
}

variable "enable_ip_reputation" {
  description = "Attach AWSManagedRulesAmazonIpReputationList."
  type        = bool
  default     = true
}

variable "enable_anonymous_ip" {
  description = "Attach AWSManagedRulesAnonymousIpList. Blocks Tor/VPN/proxies. Enable only if your traffic doesn't legitimately come through them."
  type        = bool
  default     = false
}

###############################################################################
# Bot Control - opt-in. Cost: ~$10/Web ACL/month + $1 per million requests
# inspected. Default off so cost is explicit at the leaf.
###############################################################################

variable "enable_bot_control" {
  description = <<-EOT
    Attach AWSManagedRulesBotControlRuleSet. Off by default because it adds a
    standalone monthly fee (~$10/Web ACL) plus per-request charges. Turn on
    after baselining traffic in Count mode for a week so you know which
    sub-rules to override - SignalAutomatedBrowser commonly trips legitimate
    headless integrations.
  EOT
  type        = bool
  default     = false
}

variable "bot_control_inspection_level" {
  description = "COMMON or TARGETED. TARGETED unlocks the ML / CAPTCHA / challenge sub-rules; costs more."
  type        = string
  default     = "COMMON"
  validation {
    condition     = contains(["COMMON", "TARGETED"], var.bot_control_inspection_level)
    error_message = "bot_control_inspection_level must be COMMON or TARGETED."
  }
}

variable "bot_control_overrides_to_count" {
  description = <<-EOT
    AWSManagedRulesBotControlRuleSet sub-rules to set to Count instead of
    Block while you tune. Empty = run all sub-rules at their default actions.
  EOT
  type        = list(string)
  default     = []
}

###############################################################################
# Geo allow / block. List of ISO 3166-1 alpha-2 country codes (e.g. ["PR","US"]).
###############################################################################

variable "geo_allow_country_codes" {
  description = <<-EOT
    Two-letter ISO country codes that are ALLOWED. When non-empty, all other
    countries are blocked. Useful for "we only serve PR + US" workloads.
    Mutually exclusive with geo_block_country_codes - set one or the other.
  EOT
  type        = list(string)
  default     = []
}

variable "geo_block_country_codes" {
  description = <<-EOT
    Two-letter ISO country codes that are BLOCKED. All other countries are
    allowed (subject to other rules). Mutually exclusive with
    geo_allow_country_codes.
  EOT
  type        = list(string)
  default     = []
}

###############################################################################
# IP allow / deny lists. Allow takes priority over every other rule -
# legitimate clients you've vetted skip every managed rule, every rate limit,
# everything. Use sparingly.
###############################################################################

variable "allow_ip_cidrs" {
  description = <<-EOT
    CIDRs allowed unconditionally. Evaluated first (priority -10). A non-empty
    list creates an aws_wafv2_ip_set named '<name>-allow' and a rule that
    short-circuits to Allow. Use for vetted partners, internal scanners,
    health-check sources, etc.
  EOT
  type        = list(string)
  default     = []
}

variable "deny_ip_cidrs" {
  description = <<-EOT
    CIDRs blocked unconditionally. Evaluated right after the allow list
    (priority -5). Use for known-bad sources or to fast-block during incident
    response.
  EOT
  type        = list(string)
  default     = []
}

variable "ip_set_ipv6_allow_cidrs" {
  description = "Same as allow_ip_cidrs but for IPv6 sources."
  type        = list(string)
  default     = []
}

variable "ip_set_ipv6_deny_cidrs" {
  description = "Same as deny_ip_cidrs but for IPv6 sources."
  type        = list(string)
  default     = []
}

###############################################################################
# Custom rules - free-form rule blocks for app-specific patterns.
#
# Each entry produces one aws_wafv2_web_acl rule. Priorities are independent;
# pick numbers between 100 and 999 to avoid collisions with the managed
# baseline rules above (which sit at 0, 1, 2, 3, 10).
###############################################################################

variable "custom_rules" {
  description = <<-EOT
    Application-specific rules. Each element supports:
      name         - rule name (required, unique per WebACL)
      priority     - rule priority (required, recommend 100-999)
      action       - "allow" | "block" | "count" | "captcha" | "challenge"
      metric_name  - CloudWatch metric name (defaults to rule name)
      byte_match_statement - optional { search_string, field, positional_constraint, text_transformations }
      rate_based_statement - optional { limit, aggregate_key_type, scope_down_statement_json }

    For statements not modeled here, leave custom_rules empty and add the rule
    directly to the leaf using the aws_wafv2_web_acl_rule pattern. The point
    of this variable is to cover the common "rate-limit a path" and "block
    a header pattern" cases.
  EOT
  type = list(object({
    name        = string
    priority    = number
    action      = string
    metric_name = optional(string, "")
    byte_match_statement = optional(object({
      search_string         = string
      field                 = string # "uri_path" | "query_string" | "method" | "single_header_user_agent" | "single_header_referer"
      positional_constraint = string # EXACTLY | STARTS_WITH | ENDS_WITH | CONTAINS | CONTAINS_WORD
      text_transformations  = optional(list(string), ["NONE"])
    }))
    rate_based_statement = optional(object({
      limit                      = number
      aggregate_key_type         = optional(string, "IP")
      scope_down_uri_starts_with = optional(string, "")
    }))
  }))
  default = []
}

###############################################################################
# Logging
###############################################################################

variable "logging_destination_arns" {
  description = <<-EOT
    Optional list of CloudWatch Logs / Kinesis Firehose / S3 ARNs to send
    WAF logs to. Bucket name (or log group / firehose name) MUST start with
    'aws-waf-logs-' or PutLoggingConfiguration fails.
  EOT
  type        = list(string)
  default     = []
}

variable "logging_redacted_headers" {
  description = "Headers to redact in WAF logs. Defaults to authorization + cookie."
  type        = list(string)
  default     = ["authorization", "cookie"]
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
