###############################################################################
# osTicket ALB (Perimeter ingress) — public endpoint for osTicket
#
# A dedicated internet-facing ALB fronting the migrated osTicket instance in
# shared-prod (Production account), reached cross-VPC over the
# perimeter <-> shared-prod TGW (same mechanism as crm-alb / sftp-nlb).
#
#   <osticket_host>  ->  10.12.1.67:80   (Apache)
#
# Simpler than crm-alb: ONE hostname on ONE backend port, so the alb module's
# default target group and listener default action cover it. No second target
# group, no extra ALB egress rule, no host-header listener rules needed.
#
# TLS staging (see variables.tf):
#   1. First apply with enable_https = false -> HTTP-only ALB + ACM cert PENDING.
#      Add the CNAME(s) from the acm_validation_records output to the external
#      DNS. Cert -> ISSUED.
#   2. Set enable_https = true and re-apply -> HTTPS listener attaches and HTTP
#      301-redirects to it. Then point the hostname at alb_dns_name.
#
# The Lightsail static IP 204.236.253.33 does NOT come with us. Anything that
# allowlisted it for INBOUND access must move to this ALB's DNS name. Outbound
# allowlists move to the egress NAT EIPs (3.151.88.5 / 3.133.15.33).
###############################################################################

###############################################################################
# WAF
#
# Same managed-rule baseline as the other public ALBs. A public ticket portal
# is a standard target for credential stuffing and spam-bot signups, so this
# is the ALB that benefits most from the rate-based rule.
#
# Attachment caveat: osTicket lets users upload files to tickets, which means
# large multipart POST bodies. SizeRestrictions_BODY would block those at its
# default action, so it stays in Count (the waf-managed module's default
# override list already includes it). If attachments still fail, check
# CountedRequests on that sub-rule before touching anything else.
#
# Logging and alarms are wired in the sibling waf-logs / waf-monitoring
# leaves — add "osticket-alb-waf" to their web_acl_names lists after this
# applies.
###############################################################################

module "waf" {
  source = "../../../modules/waf-managed"

  name  = "${var.stack_name}-waf"
  scope = "REGIONAL"

  rate_limit = var.waf_rate_limit

  tags = {
    Role = "osticket-alb-waf"
  }
}

module "alb" {
  source = "../../../modules/alb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  scheme        = "internet-facing"
  ingress_cidrs = var.allowed_source_cidrs

  # osTicket speaks plain HTTP on the instance; TLS terminates at the ALB.
  target_port     = var.osticket_port
  target_protocol = "HTTP"
  target_type     = "ip"
  # Attachment is created in this leaf — needs availability_zone = "all"
  # because the target lives outside this VPC (shared-prod over TGW).
  target_ids = []

  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher

  certificate_arn = var.enable_https ? aws_acm_certificate.osticket.arn : ""
  waf_web_acl_arn = module.waf.web_acl_arn

  # Backend is cross-VPC over TGW; disable cross-zone to avoid extra cross-AZ
  # transfer (same call as crm-alb / webapps).
  cross_zone_load_balancing = false
  deletion_protection       = true

  tags = {
    Role = "osticket-alb"
  }
}

###############################################################################
# ACM certificate, DNS validation.
#
# If the zone is external (not Route53) Terraform cannot create the validation
# records, so they are emitted via the acm_validation_records output for the DNS
# admin to add once. Deliberately no aws_acm_certificate_validation resource —
# it would block the apply waiting on records Terraform does not control.
###############################################################################

resource "aws_acm_certificate" "osticket" {
  domain_name       = var.osticket_host
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Role = "osticket-alb-cert"
  }
}

###############################################################################
# Target attachment. availability_zone = "all" is required for an IP target
# outside the ALB's own VPC (shared-prod via TGW).
###############################################################################

resource "aws_lb_target_group_attachment" "osticket" {
  target_group_arn  = module.alb.target_group_arn
  target_id         = var.backend_private_ip
  port              = var.osticket_port
  availability_zone = "all"
}

###############################################################################
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name. Point the osTicket hostname (CNAME) here."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for alias records if the zone moves to Route53)."
  value       = module.alb.alb_zone_id
}

output "alb_arn" {
  description = "ALB ARN."
  value       = module.alb.alb_arn
}

output "certificate_arn" {
  description = "ACM cert ARN. Set enable_https = true once it is ISSUED."
  value       = aws_acm_certificate.osticket.arn
}

output "acm_validation_records" {
  description = <<-EOT
    DNS validation record to add to the external DNS. Add as a CNAME
    (name -> value). Once added, the cert moves to ISSUED and you can set
    enable_https = true and re-apply.
  EOT
  value = {
    for dvo in aws_acm_certificate.osticket.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

output "dns_setup_instructions" {
  description = "What the DNS admin needs to do once the ALB is up."
  value = join("\n", [
    "1. Add the ACM validation CNAME from acm_validation_records.",
    "2. After the cert is ISSUED, set enable_https = true and re-apply.",
    "3. Point the hostname at the ALB as a CNAME:",
    "     ${var.osticket_host} -> ${module.alb.alb_dns_name}",
    "4. Drop the record TTL to 60s before the final cutover from Lightsail.",
  ])
}
