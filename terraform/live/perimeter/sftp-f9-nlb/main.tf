###############################################################################
# SFTP NLB - F9 (Perimeter ingress)
#
# Internet-facing Network Load Balancer that fronts sftp-server-f9
# (private in shared-prod / Production). Same shape as the existing
# sftp-nlb / sftp-claro-nlb leaves - one TCP listener forwarding to the
# server's private IP via IP target. Cross-VPC reachability is provided by
# the existing TGW that already connects perimeter <-> shared-prod (used by
# the sibling sftp-nlb / wazuh-nlb stacks the same way).
#
# Static IPs:
#   The NLB does NOT allocate EIPs. lza-infrastructure-guardrails-1 SCP
#   denies ec2:AllocateAddress for non-LZA principals; the alternative is
#   the AWS-managed IP each AZ assigns to the NLB. Those IPs are stable
#   for the life of the NLB - they only change if the LB itself is
#   destroyed and recreated. The two IPs are exposed via the
#   `nlb_public_ips` output for partner allowlisting.
#
# Source IPs visible to the SFTP server:
#   preserve_client_ip = false (matches the sftp-nlb / wazuh-nlb decision).
#   The SFTP server's auth.log will show NLB private IPs in the perimeter
#   ingress range, not real client IPs. Allowlist enforcement happens at
#   the NLB SG layer (allowed_source_cidrs), not on the SFTP server.
###############################################################################

###############################################################################
# Security group on the NLB
###############################################################################

resource "aws_security_group" "nlb" {
  name        = "${var.stack_name}-sg"
  description = "Security group for the F9 SFTP NLB"
  vpc_id      = var.ingress_vpc_id

  tags = { Name = "${var.stack_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "sftp" {
  for_each          = toset(var.allowed_source_cidrs)
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value
  from_port         = var.sftp_port
  to_port           = var.sftp_port
  ip_protocol       = "tcp"
  description       = "SFTP from ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "to_sftp_server" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  from_port         = var.sftp_port
  to_port           = var.sftp_port
  ip_protocol       = "tcp"
  description       = "To SFTP server in shared-prod"
}

###############################################################################
# NLB
###############################################################################

module "nlb" {
  source = "../../../modules/nlb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  # SCP-blocked. NLB still gets stable AWS-managed IPs per AZ.
  allocate_eips = false

  # Default off - NLB cross-zone is billed per GB. Flip true only if a
  # single SFTP target AZ outage must keep traffic balanced.
  cross_zone_load_balancing = false

  deletion_protection = true

  security_group_ids = [aws_security_group.nlb.id]
}

###############################################################################
# Listener: SFTP port -> SFTP server private IP (raw TCP, IP target)
#
# IP targets support cross-VPC via TGW. The NLB lives in Perimeter, the
# SFTP server lives in shared-prod (Production). availability_zone="all"
# is required when the IP target is outside the NLB's own VPC.
###############################################################################

resource "aws_lb_target_group" "sftp" {
  name        = "${var.stack_name}-tg"
  target_type = "ip"
  port        = var.sftp_port
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  # Off on purpose; same return-path issue documented on the sftp-nlb /
  # wazuh-nlb agent_event tg. With SNAT on, the reply stays in-VPC
  # perimeter <-> shared-prod over TGW.
  preserve_client_ip = "false"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.sftp_port)
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "sftp" {
  target_group_arn = aws_lb_target_group.sftp.arn
  target_id        = var.sftp_server_private_ip
  port             = var.sftp_port

  # Required when the IP target is not in the NLB's own VPC. The SFTP
  # server is in shared-prod, the NLB is in perimeter, joined by TGW.
  availability_zone = "all"
}

resource "aws_lb_listener" "sftp" {
  load_balancer_arn = module.nlb.nlb_arn
  port              = var.sftp_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sftp.arn
  }
}

###############################################################################
# Discover the AWS-managed public IPs the NLB picked (one per AZ).
# Each NLB subnet attachment creates an ENI; the public IP shows up in the
# ENI association. This is the list partners allowlist.
#
# We index by subnet (count = length(var.public_subnet_ids), known at plan
# time) instead of by ENI ID (only known after apply, which breaks for_each).
# Each subnet has exactly one NLB ENI, so the filter resolves cleanly.
###############################################################################

data "aws_network_interface" "nlb_eni" {
  count = length(var.public_subnet_ids)

  filter {
    name   = "description"
    values = ["ELB net/${var.stack_name}/*"]
  }

  filter {
    name   = "subnet-id"
    values = [var.public_subnet_ids[count.index]]
  }

  depends_on = [module.nlb]
}

###############################################################################
# Outputs
###############################################################################

output "nlb_dns_name" {
  description = "DNS name of the NLB. CNAME-friendly. Resolves to the per-AZ public IPs."
  value       = module.nlb.nlb_dns_name
}

output "nlb_arn" {
  description = "NLB ARN."
  value       = module.nlb.nlb_arn
}

output "nlb_public_ips" {
  description = <<-EOT
    Per-AZ public IPv4 addresses currently assigned to the NLB. Stable
    for the life of the NLB; only change on destroy/recreate. Send these
    to F9 for allowlisting along with the DNS name.
  EOT
  value = sort([
    for eni in data.aws_network_interface.nlb_eni :
    eni.association[0].public_ip
    if length(eni.association) > 0 && eni.association[0].public_ip != ""
  ])
}
