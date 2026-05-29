output "accelerator_arn" {
  description = "Accelerator ARN."
  value       = aws_globalaccelerator_accelerator.this.id
}

output "accelerator_dns_name" {
  description = "Anycast DNS for the accelerator."
  value       = aws_globalaccelerator_accelerator.this.dns_name
}

output "accelerator_static_ips" {
  description = "Two static anycast IPs. Share these with vendors who need an allowlist."
  value       = aws_globalaccelerator_accelerator.this.ip_sets[0].ip_addresses
}

output "hosted_zone_id" {
  description = "Hosted zone ID for Route53 alias targets."
  value       = aws_globalaccelerator_accelerator.this.hosted_zone_id
}
