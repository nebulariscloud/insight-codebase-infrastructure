output "automation_log_group_name" {
  description = "CloudWatch log group used by SSM Automation in every region."
  value       = local.automation_log_group_name
}

output "automation_role_arn" {
  description = "IAM role ARN that SSM Automation assumes to write logs."
  value       = aws_iam_role.automation_logging.arn
}

output "automation_kms_key_arns" {
  description = "Map of region alias to CMK ARN for the SSM Automation log groups."
  value = {
    use1 = aws_kms_key.automation_logs_use1.arn
    use2 = aws_kms_key.automation_logs_use2.arn
    usw2 = aws_kms_key.automation_logs_usw2.arn
  }
}
