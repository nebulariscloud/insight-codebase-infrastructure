###############################################################################
# Webapps ALB (Perimeter ingress) — dedicated ALB for the CTI v7 cluster webapps
#
# A DEDICATED internet-facing ALB for this cluster (deliberately NOT the shared
# ingress-alb) so the cluster owns its own routing / WAF / access logs and can
# be torn down independently.
#
# Fronts the two webapps living privately in shared-prod (Production account):
#   - webapps server   (default target group)
#   - webapps php7.3    (second target group)
# Routed by host header on the HTTPS listener. Backends are IP targets reached
# cross-VPC over the existing perimeter <-> shared-prod TGW (same mechanism as
# sftp-nlb / wazuh-nlb).
#
# The `alb` module builds the ALB + SG + the webapps-server target group +
# listeners. This leaf adds the php7.3 target group and the two host-header
# listener rules.
###############################################################################

module "alb" {
  source = "../../../modules/alb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  scheme        = "internet-facing"
  ingress_cidrs = var.allowed_source_cidrs

  # Default target group = webapps server. HTTP backend (TLS terminates at ALB).
  target_port     = var.target_port
  target_protocol = "HTTP"
  target_type     = "ip"
  target_ids      = [var.webapps_server_private_ip]

  health_check_path    = var.health_check_path
  health_check_matcher = var.health_check_matcher

  certificate_arn = var.certificate_arn
  waf_web_acl_arn = var.waf_web_acl_arn

  # Backends are cross-VPC over TGW; disable cross-zone to avoid extra
  # cross-AZ transfer (same call as sftp-nlb).
  cross_zone_load_balancing = false
  deletion_protection       = true

  tags = {
    Cluster = "cti-v7"
    Role    = "webapps-alb"
  }
}

###############################################################################
# Second target group: webapps php7.3
###############################################################################

resource "aws_lb_target_group" "php73" {
  name        = "${var.stack_name}-php73-tg"
  port        = var.target_port
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

resource "aws_lb_target_group_attachment" "php73" {
  target_group_arn = aws_lb_target_group.php73.arn
  target_id        = var.webapps_php73_private_ip
  port             = var.target_port

  # Required when the IP target is outside the ALB's own VPC (shared-prod via TGW).
  availability_zone = "all"
}

###############################################################################
# Host-header listener rules
#
# The webapps server is the listener default action (from the module). We add
# explicit host-header rules for both apps so each hostname routes to its own
# target group.
#
# Which listener the rules attach to depends on whether a cert is set:
#   - No cert (HTTP-only interim)  -> rules on the HTTP listener, so both apps
#     are reachable over HTTP today. TODO: add ACM cert + HTTPS (see README).
#   - Cert present                 -> HTTP redirects to HTTPS (module default),
#     and the rules live on the HTTPS listener.
###############################################################################

locals {
  app_listener_arn = var.certificate_arn == "" ? module.alb.http_listener_arn : module.alb.https_listener_arn
}

resource "aws_lb_listener_rule" "server_host" {
  listener_arn = local.app_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = module.alb.target_group_arn
  }

  condition {
    host_header {
      values = [var.webapps_server_host]
    }
  }

  tags = { Name = "${var.stack_name}-rule-server" }
}

resource "aws_lb_listener_rule" "php73_host" {
  listener_arn = local.app_listener_arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.php73.arn
  }

  condition {
    host_header {
      values = [var.webapps_php73_host]
    }
  }

  tags = { Name = "${var.stack_name}-rule-php73" }
}

###############################################################################
# Outputs
###############################################################################

output "alb_dns_name" {
  description = "ALB DNS name. Point both app hostnames (CNAME/alias) here."
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID for Route53 alias records."
  value       = module.alb.alb_zone_id
}

output "alb_arn" {
  description = "ALB ARN."
  value       = module.alb.alb_arn
}

output "server_target_group_arn" {
  description = "Target group ARN for the webapps server."
  value       = module.alb.target_group_arn
}

output "php73_target_group_arn" {
  description = "Target group ARN for the webapps php7.3 server."
  value       = aws_lb_target_group.php73.arn
}
