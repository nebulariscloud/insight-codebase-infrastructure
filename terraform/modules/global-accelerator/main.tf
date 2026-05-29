###############################################################################
# AWS Global Accelerator is global but its control plane runs in us-west-2 only.
# Configure your provider in the leaf accordingly.
###############################################################################

resource "aws_globalaccelerator_accelerator" "this" {
  name            = var.name
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled = false
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_globalaccelerator_listener" "this" {
  accelerator_arn = aws_globalaccelerator_accelerator.this.id
  client_affinity = var.client_affinity
  protocol        = var.protocol

  dynamic "port_range" {
    for_each = var.listener_port_ranges
    content {
      from_port = port_range.value.from_port
      to_port   = port_range.value.to_port
    }
  }
}

resource "aws_globalaccelerator_endpoint_group" "this" {
  listener_arn          = aws_globalaccelerator_listener.this.id
  endpoint_group_region = var.alb_region

  health_check_port             = var.health_check_port
  health_check_interval_seconds = var.health_check_interval_seconds
  threshold_count               = var.threshold_count

  endpoint_configuration {
    endpoint_id                    = var.alb_arn
    weight                         = 100
    client_ip_preservation_enabled = var.client_ip_preservation
  }
}
