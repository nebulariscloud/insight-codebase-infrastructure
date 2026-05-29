###############################################################################
# Wazuh Global Accelerator
#
# Sits in front of the LZA-managed IngressALB (which fronts the Wazuh server
# in the Production account). Provides two static anycast IPs the security
# team can publish to vendors and integrations that need a stable IP set.
#
# The IngressALB itself is owned by the LZA pipeline (custom-stacks/
# ingress-alb.yaml). Don't manage it from Terraform - just point GA at it.
###############################################################################

# Discover the IngressALB in us-east-2. Lookup by name (set by LZA's
# IngressALB CFN stack to "ingress-alb"). If the LB is ever recreated,
# this picks up the new ARN automatically on the next plan.
data "aws_lb" "ingress" {
  provider = aws.alb_region
  name     = var.alb_name
}

module "ga" {
  source = "../../../modules/global-accelerator"

  name       = var.stack_name
  alb_arn    = data.aws_lb.ingress.arn
  alb_region = var.alb_region

  # IngressALB has HTTP:80 (redirects to 443) + HTTPS:443. Forward both via
  # GA so callers can hit either - the ALB enforces HTTPS at the redirect.
  listener_port_ranges = [
    { from_port = 80, to_port = 80 },
    { from_port = 443, to_port = 443 },
  ]

  # Probe the ALB on its HTTP listener (port 80). The redirect listener is
  # cheap and always returns a 301, which GA treats as healthy.
  health_check_port             = 80
  health_check_interval_seconds = 30
  threshold_count               = 3

  # Preserve client IPs through the accelerator so ALB access logs and WAF
  # see the real source IP, not GA's edge POPs.
  client_ip_preservation = true

  # Same defaults as ScriptcaseGA otherwise.
  protocol        = "TCP"
  client_affinity = "NONE"
}

###############################################################################
# Outputs - the static IPs are the whole point. Share with vendors.
###############################################################################

output "accelerator_dns_name" {
  description = "Anycast DNS for the accelerator. Use as a CNAME target if needed."
  value       = module.ga.accelerator_dns_name
}

output "accelerator_static_ips" {
  description = "Two static anycast IPv4 addresses. Share these with vendors who need to allowlist a stable IP set."
  value       = module.ga.accelerator_static_ips
}

output "accelerator_arn" {
  description = "Accelerator ARN."
  value       = module.ga.accelerator_arn
}

output "alb_arn_attached" {
  description = "ARN of the ALB the accelerator is fronting (for verification)."
  value       = data.aws_lb.ingress.arn
}
