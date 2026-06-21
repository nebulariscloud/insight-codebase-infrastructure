output "web_acl_arn" {
  description = "Pass to the alb module's waf_web_acl_arn input."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "Web ACL ID."
  value       = aws_wafv2_web_acl.this.id
}

output "web_acl_name" {
  description = "Web ACL name (= the per-WebACL CloudWatch metric name)."
  value       = aws_wafv2_web_acl.this.name
}

output "web_acl_capacity" {
  description = "WCU consumed. AWS soft-limits at 1500 by default."
  value       = aws_wafv2_web_acl.this.capacity
}

output "allow_ip_set_v4_arn" {
  description = "ARN of the IPv4 allow set, or null if none."
  value       = length(aws_wafv2_ip_set.allow_v4) == 0 ? null : aws_wafv2_ip_set.allow_v4[0].arn
}

output "deny_ip_set_v4_arn" {
  description = "ARN of the IPv4 deny set, or null if none."
  value       = length(aws_wafv2_ip_set.deny_v4) == 0 ? null : aws_wafv2_ip_set.deny_v4[0].arn
}
