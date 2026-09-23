###############################################################################
# LimeSurvey ALB (Perimeter ingress) — endpoint for the ICC LimeSurvey box
#
# A dedicated internet-facing ALB fronting the migrated icc-limesurvey instance
# in shared-prod (Production account), reached cross-VPC over the
# perimeter <-> shared-prod TGW (same mechanism as osticket-alb / crm-alb).
#
#   <alb_dns_name>  ->  10.12.1.83:80   (Apache)
#
# INTERIM STATE — HTTP only, no domain yet:
#   There is no ACM cert here. With certificate_arn = "" the alb module's HTTP
#   listener FORWARDS to the target (it only redirects-to-HTTPS when a cert is
#   present). So LimeSurvey is reachable today over HTTP at the ALB's own AWS
#   DNS name (alb_dns_name output) with zero external DNS setup.
#
#   When the domain is ready, add an aws_acm_certificate for the hostname, set
#   certificate_arn + enable_https on the module, and re-apply — HTTP then
#   301-redirects to HTTPS. Mirror osticket-alb's cert block at that point.
#   Survey traffic is UNENCRYPTED until then; acceptable only as an interim
#   state (access is already restricted to the partner allowlist below).
#
# Access is locked to the partner allowlist (var.allowed_source_cidrs), carried
# over from the source webserver SG's :443 rule — LimeSurvey is not a public
# portal.
###############################################################################

module "waf" {
  source = "../../../modules/waf-managed"

  name  = "${var.stack_name}-waf"
  scope = "REGIONAL"

  rate_limit = var.waf_rate_limit

  tags = {
    Role = "limesurvey-alb-waf"
  }
}

module "alb" {
  source = "../../../modules/alb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  scheme        = "internet-facing"
  ingress_cidrs = var.allowed_source_cidrs

  # LimeSurvey speaks plain HTTP on the instance; the ALB terminates client
  # traffic. No cert yet -> HTTP listener forwards (see the header note).
  target_port     = var.backend_port
  target_protocol = "HTTP"
  target_type     = "ip"
  # Attachment created below — needs availability_zone = "all" (target is in
  # shared-prod, outside this VPC, over TGW).
  target_ids = []

  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher

  # Interim: empty = HTTP-only. Wire an ACM cert here when the domain lands.
  certificate_arn = ""
  enable_waf      = true
  waf_web_acl_arn = module.waf.web_acl_arn

  # Backend is cross-VPC over TGW; disable cross-zone to avoid extra cross-AZ
  # transfer (same call as osticket-alb / crm-alb).
  cross_zone_load_balancing = false
  deletion_protection       = true

  tags = {
    Role = "limesurvey-alb"
  }
}

###############################################################################
# Target attachment. availability_zone = "all" is required for an IP target
# outside the ALB's own VPC (shared-prod via TGW).
###############################################################################

resource "aws_lb_target_group_attachment" "limesurvey" {
  target_group_arn  = module.alb.target_group_arn
  target_id         = var.backend_private_ip
  port              = var.backend_port
  availability_zone = "all"
}

###############################################################################
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name — hit LimeSurvey here over HTTP today (http://<alb_dns_name>). Point the real hostname (CNAME) here once the domain + cert are set up."
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

output "target_group_arn" {
  description = "Target group ARN (the icc-limesurvey box is registered here)."
  value       = module.alb.target_group_arn
}
