###############################################################################
# CRM ALB (Perimeter ingress) — public endpoint for the ICC CRM APIs
#
# A dedicated internet-facing ALB fronting the two ICC APIs that run on the
# insight-ubuntu-dev box in shared-prod (Production account), reached cross-VPC
# over the perimeter <-> shared-prod TGW (same mechanism as webapps-alb /
# sftp-nlb). Both APIs are on the SAME box, different ports:
#
#   crm.insightgrouppr.com      -> 10.12.1.71:80  (production API)
#   crm-dev.insightgrouppr.com  -> 10.12.1.71:81  (development API)
#
# Host-header routing splits the two. The module builds the ALB + SG + the
# production target group + listeners; this leaf adds the dev target group,
# both IP target attachments (az="all" for cross-VPC targets), the host rules,
# and the ACM cert.
#
# TLS staging: see variables.tf. First apply HTTP-only (enable_https=false) so
# the cert can DNS-validate against the external DNS; then flip enable_https.
###############################################################################

###############################################################################
# WAF
#
# Same managed-rule baseline as ingress-alb-waf / scriptcase-lb-waf, so all
# four public ALBs are tuned from one module. Logging and alarms for this Web
# ACL are wired up in the sibling waf-logs / waf-monitoring leaves — add
# "crm-alb-waf" to their web_acl_names lists after this applies.
#
# Rate limit note: this fronts two APIs on one box. API clients burst harder
# than browsers, so if the default trips legitimate traffic, raise
# var.waf_rate_limit rather than dropping the rule.
###############################################################################

module "waf" {
  source = "../../../modules/waf-managed"

  name  = "${var.stack_name}-waf"
  scope = "REGIONAL"

  rate_limit = var.waf_rate_limit

  # Module defaults already Count the four sub-rules that false-positive on
  # JSON API payloads (EC2MetaDataSSRF_BODY, SizeRestrictions_BODY,
  # GenericRFI_BODY, GenericRFI_QUERYARGUMENTS). Same list ingress-alb-waf uses.

  tags = {
    Cluster = "icc-crm"
    Role    = "crm-alb-waf"
  }
}

module "alb" {
  source = "../../../modules/alb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  scheme        = "internet-facing"
  ingress_cidrs = var.allowed_source_cidrs

  # Default target group = production API. HTTP backend (TLS terminates at ALB).
  target_port     = var.prod_api_port
  target_protocol = "HTTP"
  target_type     = "ip"
  # Attachments are created in this leaf (need az="all" for cross-VPC targets).
  target_ids = []

  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher

  certificate_arn = var.enable_https ? aws_acm_certificate.icc.arn : ""
  enable_waf      = true
  waf_web_acl_arn = module.waf.web_acl_arn

  # Backends are cross-VPC over TGW; disable cross-zone to avoid extra
  # cross-AZ transfer (same call as webapps-alb / sftp-nlb).
  cross_zone_load_balancing = false
  deletion_protection       = true

  tags = {
    Cluster = "icc-crm"
    Role    = "crm-alb"
  }
}

###############################################################################
# ACM certificate (SAN covering both hostnames), DNS validation.
#
# insightgrouppr.com DNS is external (not Route53), so Terraform cannot create
# the validation records. They're emitted via the acm_validation_records
# output for the DNS admin to add once. No aws_acm_certificate_validation
# resource here — it would block apply waiting on records TF doesn't control.
###############################################################################

resource "aws_acm_certificate" "icc" {
  domain_name               = var.prod_api_host
  subject_alternative_names = [var.dev_api_host]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Cluster = "icc-crm"
    Role    = "crm-alb-cert"
  }
}

###############################################################################
# Production API target group is the module default. Dev API needs its own.
###############################################################################

resource "aws_lb_target_group" "dev" {
  name        = "${var.stack_name}-dev-tg"
  port        = var.dev_api_port
  protocol    = "HTTP"
  vpc_id      = var.ingress_vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    interval            = 30
    timeout             = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-dev-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# ALB egress to the DEV API port.
#
# The alb module opens egress for exactly one port — `target_port` (here the
# prod API, :80). This leaf adds a SECOND backend port (:81) that the module
# knows nothing about, so without this rule the ALB's own security group drops
# its health checks to :81 before they leave. Symptom: zero SYN packets ever
# arrive at the instance on 81 while :80 works fine (confirmed by packet
# capture on the box, 2026-07-28).
#
# Keep var.alb_egress_cidrs aligned with the module's egress_cidrs default.
###############################################################################

resource "aws_vpc_security_group_egress_rule" "alb_to_dev_api" {
  for_each = toset(var.alb_egress_cidrs)

  security_group_id = module.alb.security_group_id
  cidr_ipv4         = each.value
  from_port         = var.dev_api_port
  to_port           = var.dev_api_port
  ip_protocol       = "tcp"
  description       = "To dev API backend ${each.value}:${var.dev_api_port}"
}

###############################################################################
# Target attachments — same box, two ports. availability_zone = "all" is
# required because the IP target is outside the ALB's own VPC (shared-prod
# via TGW).
###############################################################################

resource "aws_lb_target_group_attachment" "prod" {
  target_group_arn  = module.alb.target_group_arn
  target_id         = var.backend_private_ip
  port              = var.prod_api_port
  availability_zone = "all"
}

resource "aws_lb_target_group_attachment" "dev" {
  target_group_arn  = aws_lb_target_group.dev.arn
  target_id         = var.backend_private_ip
  port              = var.dev_api_port
  availability_zone = "all"
}

###############################################################################
# Host-header listener rules
#
# The production API is the listener default action (from the module). We add
# explicit host-header rules for both hostnames so each routes to its port.
# Which listener the rules attach to depends on enable_https:
#   - false (HTTP-only interim) -> rules on the HTTP listener.
#   - true                      -> HTTP redirects to HTTPS (module default),
#                                  rules live on the HTTPS listener.
###############################################################################

locals {
  app_listener_arn = var.enable_https ? module.alb.https_listener_arn : module.alb.http_listener_arn
}

resource "aws_lb_listener_rule" "prod_host" {
  listener_arn = local.app_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = module.alb.target_group_arn
  }

  condition {
    host_header {
      values = [var.prod_api_host]
    }
  }

  tags = { Name = "${var.stack_name}-rule-prod" }
}

resource "aws_lb_listener_rule" "dev_host" {
  listener_arn = local.app_listener_arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dev.arn
  }

  condition {
    host_header {
      values = [var.dev_api_host]
    }
  }

  tags = { Name = "${var.stack_name}-rule-dev" }
}

###############################################################################
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name. Point both hostnames (CNAME) here in external DNS."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for alias records if the zone ever moves to Route53)."
  value       = module.alb.alb_zone_id
}

output "alb_arn" {
  description = "ALB ARN."
  value       = module.alb.alb_arn
}

output "certificate_arn" {
  description = "ACM cert ARN. Set enable_https=true once it's ISSUED."
  value       = aws_acm_certificate.icc.arn
}

output "acm_validation_records" {
  description = <<-EOT
    DNS validation records to add to the external DNS for insightgrouppr.com.
    Add each as a CNAME (name -> value). Once added, the cert moves to ISSUED
    and you can set enable_https=true and re-apply.
  EOT
  value = {
    for dvo in aws_acm_certificate.icc.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

output "dns_setup_instructions" {
  description = "What the external DNS admin needs to create once the ALB is up."
  value = join("\n", [
    "1. Add the ACM validation CNAME(s) from acm_validation_records (one per hostname).",
    "2. After the cert is ISSUED, set enable_https=true and re-apply.",
    "3. Point both hostnames at the ALB as CNAMEs:",
    "     ${var.prod_api_host} -> ${module.alb.alb_dns_name}",
    "     ${var.dev_api_host}  -> ${module.alb.alb_dns_name}",
  ])
}
