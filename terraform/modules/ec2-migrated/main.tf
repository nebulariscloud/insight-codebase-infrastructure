###############################################################################
# Security group
###############################################################################

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Security group for ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = {
    for idx, r in var.ingress_rules :
    "${r.from_port}-${r.to_port}-${r.protocol}-${idx}" => r
  }

  security_group_id = aws_security_group.this.id
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  description       = each.value.description

  # Single CIDR per rule resource - flatten in callers if you have multiple.
  cidr_ipv4 = each.value.cidr_blocks[0]
}

# All-egress (standard for application instances)
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

###############################################################################
# Instance
###############################################################################

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  private_ip                  = var.private_ip == "" ? null : var.private_ip
  key_name                    = var.key_name == "" ? null : var.key_name
  iam_instance_profile        = var.iam_instance_profile == "" ? null : var.iam_instance_profile
  vpc_security_group_ids      = concat([aws_security_group.this.id], var.additional_security_group_ids)
  ebs_optimized               = var.ebs_optimized
  monitoring                  = var.monitoring
  disable_api_termination     = var.disable_api_termination
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imdsv2_required ? "required" : "optional"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    encrypted             = true
    kms_key_id            = var.root_volume_kms_key_id == "" ? null : var.root_volume_kms_key_id
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${var.name}-root" })
  }

  user_data                   = var.user_data == "" ? null : var.user_data
  user_data_replace_on_change = false

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    ignore_changes = [
      # AMI changes routinely (patching, rebakes). Don't trigger replacement
      # here - manage AMI rotation explicitly when you intend to.
      ami,
      user_data,
    ]
  }
}

resource "aws_ebs_volume" "extra" {
  for_each = {
    for v in var.additional_ebs_volumes : v.device_name => v
  }

  availability_zone = aws_instance.this.availability_zone
  size              = each.value.size
  type              = each.value.type
  iops              = try(each.value.iops, null)
  throughput        = try(each.value.throughput, null)
  snapshot_id       = try(each.value.snapshot_id, null)
  encrypted         = true
  kms_key_id        = try(each.value.kms_key_id, null)

  tags = merge(var.tags, { Name = "${var.name}-${each.value.device_name}" })
}

resource "aws_volume_attachment" "extra" {
  for_each = aws_ebs_volume.extra

  device_name = each.key
  volume_id   = each.value.id
  instance_id = aws_instance.this.id
}

###############################################################################
# Elastic IP
###############################################################################

resource "aws_eip" "this" {
  count    = var.allocate_eip ? 1 : 0
  instance = aws_instance.this.id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-eip" })
}

###############################################################################
# Route53
###############################################################################

resource "aws_route53_record" "this" {
  count   = var.route53 == null ? 0 : 1
  zone_id = var.route53.hosted_zone_id
  name    = var.route53.record_name
  type    = "A"
  ttl     = var.route53.ttl
  records = [
    var.route53.use_public_ip ? (
      var.allocate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
    ) : aws_instance.this.private_ip
  ]
}
