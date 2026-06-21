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

  web_acls = {
    ingress = {
      name   = var.ingress_web_acl_name
      scope  = "REGIONAL"
      region = var.region
    }
    scriptcase = {
      name   = var.scriptcase_web_acl_name
      scope  = "REGIONAL"
      region = var.region
    }
  }

  sns_email_high   = var.sns_email_high
  sns_email_medium = var.sns_email_medium
  sns_email_low    = var.sns_email_low

  # Defaults are intentionally generous so the alarms don't chirp on
  # background internet noise. After a week of dashboard data, narrow
  # these by editing terraform.tfvars.
  blocked_requests_threshold      = 1000
  rate_limit_block_threshold      = 200
  common_rule_set_block_threshold = 500
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
