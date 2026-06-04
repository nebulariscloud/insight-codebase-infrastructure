###############################################################################
# Wazuh Global Accelerator
#
# Sits in front of the LZA-managed IngressALB (which fronts the Wazuh server
# in the Production account). Provides two static anycast IPs the security
# team can publish to vendors and integrations that need a stable IP set.
#
# The IngressALB itself is owned by the LZA pipeline (custom-stacks/
# ingress-alb.yaml). Don't manage it from Terraform - just point GA at it.
#
# As of the wazuh-nlb stack, this accelerator also fronts the new NLB on
# 1514/1515 for Wazuh agent events and enrollment. Same two anycast IPs
# now serve all four ports: 80/443 (-> ALB) and 1514/1515 (-> NLB).
#
# Plus a dedicated UDP 514 listener -> NLB for syslog ingestion. UDP needs
# its own listener because GA listeners are single-protocol; you cannot mix
# TCP and UDP on the same one.
###############################################################################

# Discover the IngressALB in us-east-2. Lookup by name (set by LZA's
# IngressALB CFN stack to "ingress-alb"). If the LB is ever recreated,
# this picks up the new ARN automatically on the next plan.
data "aws_lb" "ingress" {
  provider = aws.alb_region
  name     = var.alb_name
}

# Discover the wazuh-nlb in the same account/region. Lives in
# terraform/live/perimeter/wazuh-nlb. Like the ALB lookup above, by name
# instead of remote_state so a recreate Just Works on next plan.
data "aws_lb" "wazuh_nlb" {
  provider = aws.alb_region
  name     = var.nlb_name
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
# Wazuh agent listener (1514-1515) on the same accelerator -> NLB
#
# The GA module above only models a single listener+endpoint pair (matches
# the ScriptcaseGA pattern). Extend the same accelerator with raw GA
# resources for the NLB path rather than reshape the module.
#
# One listener covers both ports as a contiguous range. GA preserves the
# original destination port, so traffic on :1514 hits the NLB's :1514
# listener and traffic on :1515 hits its :1515 listener.
###############################################################################

resource "aws_globalaccelerator_listener" "wazuh_agent" {
  accelerator_arn = module.ga.accelerator_arn
  protocol        = "TCP"
  client_affinity = "NONE"

  port_range {
    from_port = var.agent_event_port
    to_port   = var.agent_enroll_port
  }
}

resource "aws_globalaccelerator_endpoint_group" "wazuh_agent" {
  listener_arn          = aws_globalaccelerator_listener.wazuh_agent.id
  endpoint_group_region = var.alb_region

  # Probe the NLB on the events port. Both NLB target groups have TCP
  # health checks against the Wazuh manager directly, so this just
  # confirms the NLB itself is up.
  health_check_port             = var.agent_event_port
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id = data.aws_lb.wazuh_nlb.arn
    weight      = 100
    # Preserve client IP all the way through: GA -> NLB -> EC2. The NLB
    # target groups already have preserve_client_ip = "true", so the Wazuh
    # manager sees the real agent source IP.
    client_ip_preservation_enabled = true
  }
}

###############################################################################
# Wazuh syslog listener (UDP 514) on the same accelerator -> NLB
#
# Separate listener because GA listeners are single-protocol. The previous
# attempt (a hand-edit) ended up associated with the existing TCP 443 path,
# which silently dropped all syslog traffic - syslog is UDP, and even if it
# were TCP the listener was on 443 not 514.
#
# Health-checking a UDP path is awkward (no response semantics), so we probe
# TCP on the agent events port (1514) instead. If 1514 is up, the manager
# is almost certainly listening on 514 too.
###############################################################################

resource "aws_globalaccelerator_listener" "wazuh_syslog" {
  accelerator_arn = module.ga.accelerator_arn
  protocol        = "UDP"
  client_affinity = "NONE"

  port_range {
    from_port = var.syslog_port
    to_port   = var.syslog_port
  }
}

resource "aws_globalaccelerator_endpoint_group" "wazuh_syslog" {
  listener_arn          = aws_globalaccelerator_listener.wazuh_syslog.id
  endpoint_group_region = var.alb_region

  # GA UDP endpoint groups still take a TCP health-check port. Probe 1514
  # for the same reason as on the NLB target group: there's no UDP probe.
  health_check_port             = var.agent_event_port
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id = data.aws_lb.wazuh_nlb.arn
    weight      = 100
    # NLB UDP target groups always preserve client IP - keep this on so the
    # Wazuh manager logs the real syslog sender IP.
    client_ip_preservation_enabled = true
  }
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

output "nlb_arn_attached" {
  description = "ARN of the NLB the 1514-1515 listener is forwarding to (for verification)."
  value       = data.aws_lb.wazuh_nlb.arn
}
