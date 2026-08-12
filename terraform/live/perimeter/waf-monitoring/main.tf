###############################################################################
# WAF monitoring (Perimeter / us-east-2)
#
# Builds the alarm + dashboard + SNS layer for the two CFN-managed Web ACLs.
# The Web ACLs already emit CloudWatch metrics with sampled requests on
# (every rule has CloudWatchMetricsEnabled: true), so this leaf just wires
# the consumers - no Web ACL changes.
###############################################################################

module "waf_monitoring" {
  source = "../../../modules/waf-monitoring"

  name = "perimeter-waf"

  # Keys feed alarm names (perimeter-waf-<key>-<alarm-type>) and are therefore
  # stable identifiers. Thresholds come from tfvars per Web ACL, falling back to
  # the module defaults when unset.
  web_acls = {
    for key, acl in var.web_acls : key => {
      name   = acl.name
      scope  = "REGIONAL"
      region = var.region

      blocked_requests_threshold       = acl.blocked_requests_threshold
      rate_limit_block_threshold       = acl.rate_limit_block_threshold
      common_rule_set_block_threshold  = acl.common_rule_set_block_threshold
      known_bad_inputs_block_threshold = acl.known_bad_inputs_block_threshold
    }
  }

  sns_email_high   = var.sns_email_high
  sns_email_medium = var.sns_email_medium
  sns_email_low    = var.sns_email_low

  # Fallbacks for any Web ACL that does not set its own override in tfvars.
  # Sized for a low-traffic Web ACL, since a new one added to this leaf is more
  # likely to resemble scriptcase than the busy ingress ALB. Per-ACL values in
  # terraform.tfvars are the real configuration — these just stop an unset
  # threshold from being wildly wrong in either direction.
  blocked_requests_threshold       = 600
  rate_limit_block_threshold       = 100
  common_rule_set_block_threshold  = 400
  known_bad_inputs_block_threshold = 300
}

output "sns_topic_high_arn" {
  description = "ARN of the High severity WAF alarm topic."
  value       = module.waf_monitoring.sns_topic_high_arn
}

output "sns_topic_medium_arn" {
  description = "ARN of the Medium severity WAF alarm topic."
  value       = module.waf_monitoring.sns_topic_medium_arn
}

output "sns_topic_low_arn" {
  description = "ARN of the Low severity WAF alarm topic."
  value       = module.waf_monitoring.sns_topic_low_arn
}

output "dashboard_name" {
  description = "Open in CloudWatch -> Dashboards -> <name>."
  value       = module.waf_monitoring.dashboard_name
}

output "alarm_names" {
  description = "Alarm names for verification."
  value       = module.waf_monitoring.alarm_names
}

output "effective_thresholds" {
  description = "Resolved threshold per Web ACL after overrides. Confirms a tfvars override actually took effect instead of silently falling back to the default."
  value       = module.waf_monitoring.effective_thresholds
}
