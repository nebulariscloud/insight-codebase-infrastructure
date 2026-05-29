output "web_acl_arn" {
  description = "Pass to the alb module's waf_web_acl_arn input."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "Web ACL ID."
  value       = aws_wafv2_web_acl.this.id
}

output "web_acl_capacity" {
  description = "WCU consumed. AWS soft-limits at 1500 by default."
  value       = aws_wafv2_web_acl.this.capacity
}
