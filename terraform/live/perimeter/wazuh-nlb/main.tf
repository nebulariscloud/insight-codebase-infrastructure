###############################################################################
# Wazuh NLB (Perimeter ingress)
#
# Internet-facing Network Load Balancer that gives the Wazuh deployment two
# capabilities the existing ALB cannot:
#   - raw TCP listeners on 1514 / 1515 for Wazuh agent traffic
#   - raw UDP listener on 514 for syslog ingestion (ALBs are HTTP-only,
#     and standard syslog is UDP)
#   - stable EIPs (one per AZ) so customers can allowlist a fixed IP set
#
# Listener layout:
#   :443  -> existing IngressALB (ALB-as-target). Dashboard/API traffic still
#            flows through WAF + ALB listener rules. The NLB just gets us
#            stable IPs in front of it.
#   :1514 -> raw TCP to the Wazuh manager EC2 IPs (cross-VPC via TGW).
#   :1515 -> raw TCP to the Wazuh manager EC2 IPs (cross-VPC via TGW).
#   :514  -> raw UDP to the Wazuh manager EC2 IPs (syslog input, cross-VPC).
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
  name = "${var.stack_name}-sg"
  # NOTE: The exact wording of this description matters because changing it
  # forces SG replacement (AWS doesn't allow updating description in-place
  # on an SG), and our SG has a fixed name (`wazuh-nlb-sg`) which conflicts
  # with the create_before_destroy lifecycle. Keep the original wording -
  # add new ports to comments inside the resource, not to the description.
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

# 514/UDP - syslog input (RFC 3164 / RFC 5424). MUST be UDP; a TCP rule here
# would silently accept connections that the manager will never read.
resource "aws_vpc_security_group_ingress_rule" "syslog" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value
  from_port         = var.syslog_port
  to_port           = var.syslog_port
  ip_protocol       = "udp"
  description       = "Wazuh syslog (UDP) from ${each.value}"
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

resource "aws_vpc_security_group_egress_rule" "to_wazuh_syslog" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = var.syslog_port
  to_port           = var.syslog_port
  ip_protocol       = "udp"
  description       = "To Wazuh manager (syslog UDP)"
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
# preserve_client_ip toggle (FIXED to false for this stack):
#   - With it on, the manager has to reply directly to the public agent IP.
#     But the manager's default 0.0.0.0/0 route exits via the egress /
#     inspection VPC, not back through Perimeter where the NLB lives. A
#     stateful device on that asymmetric path RSTs the SYN-ACK after ~1ms,
#     so the TLS handshake never completes. Symptom: openssl s_client
#     connects, then write returns ECONNRESET with 0 bytes read.
#   - With it off, the NLB SNATs to its own VPC IPs, the manager replies
#     to the NLB symmetrically (in-VPC), and the NLB returns to the real
#     client. Trade-off: Wazuh logs the NLB private IPs as the agent
#     source, not the real public IP.
#   - The earlier hub-spoke topology was supposed to make preserve = true
#     work, but in practice the egress/inspection path still drops returns,
#     so we keep this off until that path is reworked end to end.
###############################################################################

resource "aws_lb_target_group" "agent_event" {
  name        = "${var.stack_name}-event"
  target_type = "ip"
  port        = var.agent_event_port
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  # IMPORTANT: kept false on purpose. Setting this to true breaks return-path
  # routing for our deployment - the manager's reply to a public agent has
  # to leave shared-prod via its default 0.0.0.0/0 route, which goes through
  # the egress/inspection VPC instead of back through the Perimeter ingress
  # VPC where the NLB lives. A stateful device on that asymmetric path RSTs
  # the SYN-ACK after ~1ms, killing every TLS handshake before any bytes
  # flow. With this off the NLB SNATs and the path stays symmetric.
  preserve_client_ip = "false"

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

  # See the long comment on aws_lb_target_group.agent_event above. Same
  # asymmetric-routing reason: keep false so the NLB SNATs and the manager's
  # reply path stays inside the Perimeter <-> shared-prod TGW pair.
  preserve_client_ip = "false"

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
# Listener: 514/UDP -> Wazuh manager (raw UDP, IP target)
#
# Standard syslog (RFC 3164) is UDP, fire-and-forget. Wazuh's syslog input
# does not respond, so the asymmetric-routing concerns that affect TCP
# do not apply here - there is no reply path to break.
#
# NLB UDP target groups always preserve client IP (the option cannot be
# disabled), which is what we want anyway: the manager will log the real
# syslog sender IP for source attribution.
#
# Health checks: UDP target groups can't be probed with UDP (no response
# semantics). Probe TCP on the agent events port (1514) instead - if the
# manager process is up enough to listen on 1514, it's also up enough to
# receive syslog on 514. Standard NLB UDP health-check pattern.
###############################################################################

resource "aws_lb_target_group" "syslog" {
  name        = "${var.stack_name}-syslog"
  target_type = "ip"
  port        = var.syslog_port
  protocol    = "UDP"
  vpc_id      = var.ingress_vpc_id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.agent_event_port)
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-syslog" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "syslog" {
  for_each         = toset(var.wazuh_manager_ips)
  target_group_arn = aws_lb_target_group.syslog.arn
  target_id        = each.value
  port             = var.syslog_port

  # Same cross-VPC reason as the TCP target groups: the manager lives in
  # shared-prod, the NLB in Perimeter, joined by TGW.
  availability_zone = "all"
}

resource "aws_lb_listener" "syslog" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = var.syslog_port
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.syslog.arn
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
# security group allows 1514/1515 inbound. Because preserve_client_ip is
# disabled on the IP target groups above, the manager only sees traffic
# sourced from the NLB's private IPs in the Perimeter ingress VPC, so the
# SG can be scoped to the ingress VPC CIDR (e.g. 10.0.0.0/20) rather than
# 0.0.0.0/0. That SG is in shared-prod, managed wherever you manage that
# EC2 - either LZA or another Terraform leaf.
###############################################################################
