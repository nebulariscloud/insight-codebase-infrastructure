###############################################################################
# Wazuh NLB (Perimeter ingress)
#
# Internet-facing Network Load Balancer that gives the Wazuh deployment two
# capabilities the existing ALB cannot:
#   - raw TCP listeners on 1514 / 1515 for Wazuh agent traffic
#   - stable EIPs (one per AZ) so customers can allowlist a fixed IP set
#
# Listener layout:
#   :443  -> existing IngressALB (ALB-as-target). Dashboard/API traffic still
#            flows through WAF + ALB listener rules. The NLB just gets us
#            stable IPs in front of it.
#   :1514 -> raw TCP to the Wazuh manager EC2 IPs (cross-VPC via TGW).
#   :1515 -> raw TCP to the Wazuh manager EC2 IPs (cross-VPC via TGW).
#
# This stack does NOT manage:
#   - The IngressALB itself (LZA's ingress-alb.yaml owns it)
#   - The Wazuh manager EC2 (lives in shared-prod / Production)
#   - Route53 records (add a separate dns leaf if/when you want a friendly DNS
#     name pointing at module.nlb.nlb_dns_name)
#   - The legacy wazuh-ga accelerator (sibling stack; keep it running until
#     consumers cut over to these EIPs, then destroy that leaf)
###############################################################################

# Look up the existing LZA-managed ALB so we can register it as a target on
# the NLB's :443 listener. ARN is discovered, not hardcoded - if LZA rebuilds
# the ALB, the next plan picks up the new ARN automatically.
data "aws_lb" "ingress_alb" {
  name = var.ingress_alb_name
}

###############################################################################
# Security group for the NLB
#
# NLBs historically had no SGs; modern NLBs do. We attach one so we can
# control inbound at the LB layer instead of relying on backend SGs alone.
# Note: SG rules apply to client traffic. Health checks from the NLB to its
# targets are not gated by this SG.
###############################################################################

resource "aws_security_group" "nlb" {
  name        = "${var.stack_name}-sg"
  description = "Security group for the Wazuh NLB - inbound 443/1514/1515"
  vpc_id      = var.ingress_vpc_id

  tags = { Name = "${var.stack_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# 443 from the world (dashboard / API)
# Description chars must match AWS allowlist: a-zA-Z0-9 . _ - : / ( ) # , @ [ ] + = & ; { } ! $ *
# (no '>' or other arrows)
resource "aws_vpc_security_group_ingress_rule" "https_world" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = var.https_port
  to_port           = var.https_port
  ip_protocol       = "tcp"
  description       = "HTTPS from internet to ALB target"
}

# 1514 / 1515 - configurable source CIDRs (defaults to world, tighten in tfvars)
resource "aws_vpc_security_group_ingress_rule" "agent_event" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value
  from_port         = var.agent_event_port
  to_port           = var.agent_event_port
  ip_protocol       = "tcp"
  description       = "Wazuh agent events from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "agent_enroll" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value
  from_port         = var.agent_enroll_port
  to_port           = var.agent_enroll_port
  ip_protocol       = "tcp"
  description       = "Wazuh agent enrollment from ${each.value}"
}

# Egress to backends (ALB SG and Wazuh manager via TGW). NLBs forward source
# IPs by default, so the LB itself doesn't NAT - but the SG attached to the
# NLB still gates outbound. Allow the three target ports broadly within RFC1918.
resource "aws_vpc_security_group_egress_rule" "to_alb" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = var.https_port
  to_port           = var.https_port
  ip_protocol       = "tcp"
  description       = "To ALB target HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "to_wazuh_event" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = var.agent_event_port
  to_port           = var.agent_event_port
  ip_protocol       = "tcp"
  description       = "To Wazuh manager (events)"
}

resource "aws_vpc_security_group_egress_rule" "to_wazuh_enroll" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = var.agent_enroll_port
  to_port           = var.agent_enroll_port
  ip_protocol       = "tcp"
  description       = "To Wazuh manager (enrollment)"
}

###############################################################################
# NLB itself
###############################################################################

module "nlb" {
  source = "../../../modules/nlb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  # NOTE: EIPs are off because the org SCP (lza-infrastructure-guardrails-1)
  # denies ec2:AllocateAddress in this OU. The NLB still gets stable
  # AWS-managed public IPs per AZ that don't change unless the LB is
  # destroyed/recreated. Static IP exposure is provided by the existing
  # wazuh-ga Global Accelerator, which now also fronts this NLB on
  # 1514/1515 (see ../wazuh-ga/main.tf).
  allocate_eips = false

  # Default off. NLB cross-zone is billed; flip true only if needed.
  cross_zone_load_balancing = false

  deletion_protection = true

  security_group_ids = [aws_security_group.nlb.id]
}

###############################################################################
# Listener: 443 -> existing ALB (ALB-as-target pattern)
#
# This is the only listener that hits the ALB. The ALB keeps doing all of its
# work: WAF, listener rules, target group health, etc. The NLB is only here
# to provide stable IPs in front of it.
###############################################################################

resource "aws_lb_target_group" "to_alb" {
  name        = "${var.stack_name}-to-alb"
  target_type = "alb"
  port        = var.https_port
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    port                = tostring(var.https_port)
    path                = "/"
    matcher             = "200-499"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-to-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "to_alb" {
  target_group_arn = aws_lb_target_group.to_alb.arn
  target_id        = data.aws_lb.ingress_alb.arn
  port             = var.https_port
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = var.https_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.to_alb.arn
  }
}

###############################################################################
# Listeners: 1514 / 1515 -> Wazuh manager (raw TCP, IP targets)
#
# IP targets support cross-VPC via TGW, which is what we need: the NLB lives
# in Perimeter, the Wazuh manager lives in shared-prod. The TGW route between
# them must exist (it does, it's how the ALB already reaches the Wazuh API).
#
# preserve_client_ip toggle:
#   - With IP targets, NLB preserves source IP by default. The Wazuh manager
#     SG must therefore allow 1514/1515 from real client IPs (typically the
#     world, since agents come from anywhere).
#   - Set preserve_client_ip = false on the TG if you instead want to allow
#     just the NLB subnets at the manager SG. Trades visibility for a simpler
#     SG rule.
###############################################################################

resource "aws_lb_target_group" "agent_event" {
  name        = "${var.stack_name}-event"
  target_type = "ip"
  port        = var.agent_event_port
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  preserve_client_ip = "true"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.agent_event_port)
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-event" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "agent_event" {
  for_each         = toset(var.wazuh_manager_ips)
  target_group_arn = aws_lb_target_group.agent_event.arn
  target_id        = each.value
  port             = var.agent_event_port

  # Required when the IP target is not in the NLB's own VPC. Our manager
  # lives in shared-prod and is reached over TGW; the NLB sits in Perimeter
  # ingress. AWS demands availability_zone = "all" for that case.
  availability_zone = "all"
}

resource "aws_lb_listener" "agent_event" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = var.agent_event_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent_event.arn
  }
}

resource "aws_lb_target_group" "agent_enroll" {
  name        = "${var.stack_name}-enroll"
  target_type = "ip"
  port        = var.agent_enroll_port
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  preserve_client_ip = "true"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.agent_enroll_port)
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-enroll" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "agent_enroll" {
  for_each         = toset(var.wazuh_manager_ips)
  target_group_arn = aws_lb_target_group.agent_enroll.arn
  target_id        = each.value
  port             = var.agent_enroll_port

  # Same cross-VPC reason as agent_event above.
  availability_zone = "all"
}

resource "aws_lb_listener" "agent_enroll" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = var.agent_enroll_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent_enroll.arn
  }
}

###############################################################################
# Outputs - the NLB DNS name is what the wazuh-ga GA stack consumes.
###############################################################################

output "nlb_dns_name" {
  description = "DNS name of the NLB. The wazuh-ga stack consumes this so the GA can target the NLB on 1514/1515."
  value       = module.nlb.nlb_dns_name
}

output "nlb_arn" {
  description = "NLB ARN. Consumed by wazuh-ga as the endpoint for 1514/1515 listeners."
  value       = module.nlb.nlb_arn
}

output "ingress_alb_arn_attached" {
  description = "ARN of the ALB the :443 listener is forwarding to (for verification)."
  value       = data.aws_lb.ingress_alb.arn
}

###############################################################################
# Reminder: outside this stack you still need to make sure the Wazuh manager
# security group allows 1514/1515 inbound (from 0.0.0.0/0 if preserving client
# IP, or from the Perimeter ingress VPC CIDR if not). That SG is in shared-prod,
# managed wherever you manage that EC2 - either LZA or another Terraform leaf.
###############################################################################
