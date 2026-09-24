output "automation_rule_arn_lza_new" {
  description = "ARN of the automation rule that suppresses CloudFormation.4 NEW findings for AWSAccelerator-* stacks."
  value       = aws_securityhub_automation_rule.suppress_cloudformation4_lza_stacks.arn
}

output "automation_rule_arn_lza_notified" {
  description = "ARN of the automation rule that suppresses CloudFormation.4 NOTIFIED findings for AWSAccelerator-* stacks."
  value       = aws_securityhub_automation_rule.suppress_cloudformation4_lza_stacks_notified.arn
}

output "automation_rule_arn_controltower_new" {
  description = "ARN of the automation rule that suppresses CloudFormation.4 NEW findings for StackSet-AWSControlTowerBP-* stacks."
  value       = aws_securityhub_automation_rule.suppress_cloudformation4_controltower_stacks.arn
}

output "automation_rule_arn_controltower_notified" {
  description = "ARN of the automation rule that suppresses CloudFormation.4 NOTIFIED findings for StackSet-AWSControlTowerBP-* stacks."
  value       = aws_securityhub_automation_rule.suppress_cloudformation4_controltower_stacks_notified.arn
}
