output "alb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB. Use as alias target in Route53."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "Target group ARN. Register IPs/instances here."
  value       = aws_lb_target_group.this.arn
}

output "security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "http_listener_arn" {
  description = "HTTP listener ARN."
  value       = aws_lb_listener.http.arn
}

output "https_listener_arn" {
  description = "HTTPS listener ARN, if a cert was provided."
  value       = try(aws_lb_listener.https[0].arn, null)
}
