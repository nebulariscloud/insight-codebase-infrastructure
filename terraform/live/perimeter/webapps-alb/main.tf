###############################################################################
# Webapps ALB (Perimeter ingress) — public endpoint for the two webapp boxes
#
# Reproduces the source-tenant "WebappsALB" URI routing in the new tenant. The
# source ALB (254422596287 / us-east-1) split webapps.insightgrouppr.com by
# path across two backends:
#
#   named app paths (abbvieTG)  -> i-02a7982851dd09a0b (webapps php7.3)
#   everything else ("*" rule)  -> i-0fb5b86437a72deb5 (webapps server)
#
# Those two boxes are now migrated into shared-prod (Production account):
#   webapps       -> 10.12.1.65   (catch-all)
#   webapps-php73 -> 10.12.1.61   (named app paths)
#
# This dedicated internet-facing ALB in the perimeter ingress VPC fronts both,
# reaching them cross-VPC over the perimeter <-> shared-prod TGW (same as
# crm-alb / sftp-nlb). Both backends serve plain HTTP :80; TLS terminates here.
#
# The module builds the ALB + SG + the catch-all (webapps) target group +
# listeners. This leaf adds the php73 target group, both IP target attachments
# (az="all" for cross-VPC targets), the path rules, and the ACM cert.
#
# Source had a dead HTTPS :3000 listener -> "Grafana" TG with ZERO registered
# targets. It served nothing, so it is intentionally NOT reproduced here.
#
# TLS staging: see variables.tf. First apply HTTP-only (enable_https=false) so
# the cert can DNS-validate against the external DNS; then flip enable_https.
###############################################################################

module "waf" {
  source = "../../../modules/waf-managed"

  name  = "${var.stack_name}-waf"
  scope = "REGIONAL"

  rate_limit = var.waf_rate_limit

  tags = {
    Cluster = "webapps"
    Role    = "webapps-alb-waf"
  }
}

module "alb" {
  source = "../../../modules/alb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  scheme        = "internet-facing"
  ingress_cidrs = var.allowed_source_cidrs

  # Default target group = the webapps (catch-all) box. HTTP backend on :80
  # (TLS terminates at the ALB). Attachment created in this leaf (az="all").
  target_port     = var.backend_port
  target_protocol = "HTTP"
  target_type     = "ip"
  target_ids      = []

  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher

  certificate_arn = var.enable_https ? aws_acm_certificate.webapps.arn : ""
  enable_waf      = true
  waf_web_acl_arn = module.waf.web_acl_arn

  # Backends are cross-VPC over TGW; disable cross-zone to avoid extra
  # cross-AZ transfer (same call as crm-alb / sftp-nlb).
  cross_zone_load_balancing = false
  deletion_protection       = true

  tags = {
    Cluster = "webapps"
    Role    = "webapps-alb"
  }
}

###############################################################################
# ACM certificate for webapps.insightgrouppr.com, DNS validation.
#
# insightgrouppr.com DNS is external (not Route53), so Terraform cannot create
# the validation record. It's emitted via acm_validation_records for the DNS
# admin to add once. No aws_acm_certificate_validation resource — it would
# block apply waiting on a record TF doesn't control.
###############################################################################

resource "aws_acm_certificate" "webapps" {
  domain_name       = var.app_host
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Cluster = "webapps"
    Role    = "webapps-alb-cert"
  }
}

###############################################################################
# The catch-all (webapps) box is the module's default target group. The
# webapps-php73 box (named app paths) needs its own.
###############################################################################

resource "aws_lb_target_group" "php73" {
  name        = "${var.stack_name}-php73-tg"
  port        = var.backend_port
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

  tags = { Name = "${var.stack_name}-php73-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Target attachments. availability_zone = "all" is required because the IP
# targets are outside the ALB's own VPC (shared-prod via TGW).
###############################################################################

resource "aws_lb_target_group_attachment" "webapps" {
  target_group_arn  = module.alb.target_group_arn
  target_id         = var.webapps_private_ip
  port              = var.backend_port
  availability_zone = "all"
}

resource "aws_lb_target_group_attachment" "php73" {
  target_group_arn  = aws_lb_target_group.php73.arn
  target_id         = var.webapps_php73_private_ip
  port              = var.backend_port
  availability_zone = "all"
}

###############################################################################
# Path-based routing rules — the "abbvie" path set -> php73 TG.
#
# One rule per path group (ALB caps path-pattern conditions at 5 values). The
# catch-all is the listener default action (module), which forwards to the
# webapps TG — same effect as the source priority-9 "*" rule.
#
# Which listener the rules attach to depends on enable_https:
#   - false (HTTP-only interim) -> rules on the HTTP listener.
#   - true                      -> HTTP 301-redirects to HTTPS (module default),
#                                  rules live on the HTTPS listener.
###############################################################################

locals {
  app_listener_arn = var.enable_https ? module.alb.https_listener_arn : module.alb.http_listener_arn
}

resource "aws_lb_listener_rule" "php73" {
  count = length(var.php73_path_groups)

  listener_arn = local.app_listener_arn
  priority     = 100 + count.index

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.php73.arn
  }

  condition {
    path_pattern {
      values = var.php73_path_groups[count.index]
    }
  }

  tags = { Name = "${var.stack_name}-php73-${count.index}" }
}

###############################################################################
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name. Point webapps.insightgrouppr.com (CNAME) here in external DNS."
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

output "webapps_target_group_arn" {
  description = "Catch-all target group ARN (webapps box)."
  value       = module.alb.target_group_arn
}

output "php73_target_group_arn" {
  description = "Named-app-paths target group ARN (webapps-php73 box)."
  value       = aws_lb_target_group.php73.arn
}

output "certificate_arn" {
  description = "ACM cert ARN. Set enable_https=true once it's ISSUED."
  value       = aws_acm_certificate.webapps.arn
}

output "acm_validation_records" {
  description = <<-EOT
    DNS validation record(s) to add to the external DNS for insightgrouppr.com.
    Add each as a CNAME (name -> value). Once added, the cert moves to ISSUED
    and you can set enable_https=true and re-apply.
  EOT
  value = {
    for dvo in aws_acm_certificate.webapps.domain_validation_options :
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
    "1. Add the ACM validation CNAME from acm_validation_records.",
    "2. After the cert is ISSUED, set enable_https=true and re-apply.",
    "3. Point the hostname at the ALB as a CNAME:",
    "     ${var.app_host} -> ${module.alb.alb_dns_name}",
  ])
}
