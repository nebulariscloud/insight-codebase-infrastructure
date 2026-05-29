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

variable "logging_destination_arns" {
  description = "Optional list of CloudWatch Logs / Kinesis Firehose / S3 ARNs to send WAF logs to."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
