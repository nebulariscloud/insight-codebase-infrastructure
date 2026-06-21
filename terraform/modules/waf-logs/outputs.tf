output "bucket_arn" {
  description = "ARN of the WAF logs bucket. Pass to waf-managed.logging_destination_arns or to a new aws_wafv2_web_acl_logging_configuration resource."
  value       = aws_s3_bucket.waf_logs.arn
}

output "bucket_name" {
  description = "Name of the WAF logs bucket."
  value       = aws_s3_bucket.waf_logs.id
}

output "kms_key_arn" {
  description = "CMK ARN encrypting the WAF logs bucket."
  value       = aws_kms_key.waf_logs.arn
}

output "kms_alias" {
  description = "KMS alias for the WAF logs key."
  value       = aws_kms_alias.waf_logs.name
}
