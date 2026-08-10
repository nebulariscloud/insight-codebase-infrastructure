output "sns_topic_high_arn" {
  description = "ARN of the High severity SNS topic. Subscribe pager / on-call rotation here."
  value       = aws_sns_topic.high.arn
}

output "sns_topic_medium_arn" {
  description = "ARN of the Medium severity SNS topic."
  value       = aws_sns_topic.medium.arn
}

output "sns_topic_low_arn" {
  description = "ARN of the Low severity SNS topic, or null if not enabled."
  value       = length(aws_sns_topic.low) == 0 ? null : aws_sns_topic.low[0].arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name (open via CloudWatch console)."
  value       = length(aws_cloudwatch_dashboard.this) == 0 ? null : aws_cloudwatch_dashboard.this[0].dashboard_name
}

output "alarm_names" {
  description = "All alarm names created by this module, keyed by Web ACL id and alarm type."
  value = merge(
    { for k, a in aws_cloudwatch_metric_alarm.blocked_total : "${k}-blocked-total" => a.alarm_name },
    { for k, a in aws_cloudwatch_metric_alarm.rate_limit_blocks : "${k}-rate-limit-blocks" => a.alarm_name },
    { for k, a in aws_cloudwatch_metric_alarm.common_rule_blocks : "${k}-common-ruleset-blocks" => a.alarm_name },
    { for k, a in aws_cloudwatch_metric_alarm.known_bad_inputs_blocks : "${k}-known-bad-inputs-blocks" => a.alarm_name },
    { for k, a in aws_cloudwatch_metric_alarm.metric_liveness : "${k}-no-metrics" => a.alarm_name },
  )
}

output "effective_thresholds" {
  description = <<-EOT
    Resolved threshold per Web ACL after per-ACL overrides are applied over the
    module defaults. Useful for confirming a tfvars override actually took
    effect rather than silently falling back to the default.
  EOT
  value       = local.thresholds
}

output "metrics_namespace" {
  description = <<-EOT
    The CloudWatch namespace these alarms watch. Exposed so a verification
    step can assert it rather than assume it — the June 2026 delivery shipped
    "AWS/WAFv2" (lowercase v) against the real "AWS/WAFV2" and every alarm sat
    in OK for seven weeks watching nothing.

    Verify with:
      aws cloudwatch list-metrics --namespace AWS/WAFV2 --region <region>
  EOT
  value       = "AWS/WAFV2"
}
