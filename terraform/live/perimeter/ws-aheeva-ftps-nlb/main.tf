###############################################################################
# WS Aheeva FTPS NLB (Perimeter ingress) — Wave 2
#
# Internet-facing NLB that fronts WS Aheeva (private in shared-prod) for the
# clients' daily FTPS file drop. TCP passthrough to WS Aheeva's private IP over
# the perimeter <-> shared-prod TGW (same IP-target pattern as sftp-nlb).
#
# FTPS = implicit TLS on the control port (990) + a passive data port range.
# TLS terminates on WS Aheeva itself (the FTPS server), NOT here — the NLB is
# pure TCP passthrough, which is what FTPS-over-NLB requires.
#
# LISTENER QUOTA WARNING: an NLB needs one listener + one target group PER
# PORT. The source passive range is 40000-40500 (501 ports) which exceeds the
# default NLB listener quota (50). NARROW the passive range in the Aheeva FTPS
# config to <= ~40 ports and match ftps_passive_from/to here. See README.
###############################################################################

locals {
  passive_ports = range(var.ftps_passive_from, var.ftps_passive_to + 1)
  all_ports     = concat([var.ftps_control_port], local.passive_ports)
}

###############################################################################
# NLB security group — FTPS control + passive from client CIDRs
###############################################################################

resource "aws_security_group" "nlb" {
  name        = "${var.stack_name}-sg"
  description = "FTPS NLB for WS Aheeva"
  vpc_id      = var.ingress_vpc_id

  tags = { Name = "${var.stack_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# One ingress rule per (port x client CIDR). Control + passive ports.
resource "aws_vpc_security_group_ingress_rule" "ftps" {
  for_each = {
    for pair in setproduct(local.all_ports, var.allowed_source_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  description       = "FTPS ${each.value.port} from ${each.value.cidr}"
}

resource "aws_vpc_security_group_egress_rule" "to_ws_aheeva" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = "10.0.0.0/8"
  ip_protocol       = "-1"
  description       = "To WS Aheeva in shared-prod"
}

###############################################################################
# NLB
###############################################################################

module "nlb" {
  source = "../../../modules/nlb"

  name       = var.stack_name
  vpc_id     = var.ingress_vpc_id
  subnet_ids = var.public_subnet_ids

  allocate_eips             = false # SCP denies AllocateAddress; AWS-managed per-AZ IPs are stable
  cross_zone_load_balancing = false
  deletion_protection       = true

  security_group_ids = [aws_security_group.nlb.id]
}

###############################################################################
# One target group + listener PER FTPS port (control + passive), all pointing
# at WS Aheeva's private IP. availability_zone="all" for the cross-VPC IP target.
###############################################################################

resource "aws_lb_target_group" "ftps" {
  for_each = toset([for p in local.all_ports : tostring(p)])

  name        = "${var.stack_name}-${each.key}"
  target_type = "ip"
  port        = tonumber(each.key)
  protocol    = "TCP"
  vpc_id      = var.ingress_vpc_id

  # SNAT (preserve_client_ip off) — same return-path reasoning as sftp-nlb:
  # WS Aheeva's default route leaves shared-prod via egress/inspection, so
  # keeping the source as NLB private IPs preserves routing symmetry.
  preserve_client_ip = "false"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = each.key
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.stack_name}-${each.key}" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "ftps" {
  for_each = aws_lb_target_group.ftps

  target_group_arn  = each.value.arn
  target_id         = var.ws_aheeva_private_ip
  port              = each.value.port
  availability_zone = "all"
}

resource "aws_lb_listener" "ftps" {
  for_each = aws_lb_target_group.ftps

  load_balancer_arn = module.nlb.nlb_arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = each.value.arn
  }
}

###############################################################################
# Discover the NLB's per-AZ public IPs (clients allowlist these).
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
  description = "NLB DNS name. Give clients this + the public IPs."
  value       = module.nlb.nlb_dns_name
}

output "nlb_public_ips" {
  description = "Per-AZ public IPs the FTPS clients allowlist for outbound to us."
  value = sort([
    for eni in data.aws_network_interface.nlb_eni :
    eni.association[0].public_ip
    if length(eni.association) > 0 && eni.association[0].public_ip != ""
  ])
}
