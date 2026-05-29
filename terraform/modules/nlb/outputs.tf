output "nlb_arn" {
  description = "ARN of the NLB. Use as listener and target group parent."
  value       = aws_lb.this.arn
}

output "nlb_dns_name" {
  description = "DNS name of the NLB. CNAME-able."
  value       = aws_lb.this.dns_name
}

output "nlb_zone_id" {
  description = "Hosted zone ID of the NLB. Use as alias target in Route53."
  value       = aws_lb.this.zone_id
}

output "static_ips" {
  description = <<-EOT
    Map of subnet_id -> EIP public IP. Share the values list with clients
    for allowlisting. Empty map when allocate_eips=false.
  EOT
  value       = { for s, eip in aws_eip.this : s => eip.public_ip }
}

output "static_ips_list" {
  description = "List form of the EIPs - convenient for show/output."
  value       = [for eip in aws_eip.this : eip.public_ip]
}
