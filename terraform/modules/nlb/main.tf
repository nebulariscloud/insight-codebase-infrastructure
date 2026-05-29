###############################################################################
# Network Load Balancer
#
# Thin module: just creates the LB and its EIPs. Listeners and target groups
# are declared in the leaf root, because each NLB tends to have a bespoke
# listener mix (e.g. 443 -> ALB target, 1514 -> IP target, 1515 -> IP target).
# Packing those into module variables hides too much; let the leaf compose.
###############################################################################

# One EIP per subnet. The NLB picks them up via subnet_mapping below. These
# EIPs are the static IPs you publish to clients for allowlisting.
resource "aws_eip" "this" {
  for_each = var.allocate_eips ? toset(var.subnet_ids) : toset([])

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-eip-${each.value}"
  })
}

resource "aws_lb" "this" {
  name               = var.name
  internal           = var.scheme == "internal"
  load_balancer_type = "network"
  ip_address_type    = "ipv4"

  enable_cross_zone_load_balancing = var.cross_zone_load_balancing
  enable_deletion_protection       = var.deletion_protection

  # Newer NLBs accept SGs; only attach if caller provided some.
  security_groups = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  # Use subnet_mapping (not subnets) when attaching EIPs. Falls back to plain
  # subnets when allocate_eips=false.
  dynamic "subnet_mapping" {
    for_each = var.allocate_eips ? var.subnet_ids : []
    content {
      subnet_id     = subnet_mapping.value
      allocation_id = aws_eip.this[subnet_mapping.value].id
    }
  }

  dynamic "subnet_mapping" {
    for_each = var.allocate_eips ? [] : var.subnet_ids
    content {
      subnet_id = subnet_mapping.value
    }
  }

  tags = merge(var.tags, { Name = var.name })
}
