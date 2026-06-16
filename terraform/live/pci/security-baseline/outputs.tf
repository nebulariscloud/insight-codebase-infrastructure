output "automation_log_group_name" {
  description = "CloudWatch log group used by SSM Automation in every region."
  value       = module.security_baseline.automation_log_group_name
}

output "automation_role_arn" {
  description = "IAM role assumed by SSM Automation to write logs."
  value       = module.security_baseline.automation_role_arn
}

output "automation_kms_key_arns" {
  description = "Map of region alias to CMK ARN for the SSM Automation log groups."
  value       = module.security_baseline.automation_kms_key_arns
}

output "spoke_account_id" {
  description = "Resolved PCI account ID."
  value       = local.spoke_account_id
}
