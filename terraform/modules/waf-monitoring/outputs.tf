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
  )
}
