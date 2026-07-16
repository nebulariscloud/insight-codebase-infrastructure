###############################################################################
# DynamoDB — the ICC CRM data plane
#
# Ports the vendor's CloudShell `create-table` calls into Terraform:
#   - icc-crm, icc-crm-dev       : single-table design, PK/SK + GSI1..GSI5 (ALL)
#   - icc-crm-audit, *-audit-dev : PK/SK + GSI1 (ALL)
# All PAY_PER_REQUEST (on-demand). Attribute definitions only declare the keys
# that participate in a key schema — DynamoDB rejects unused attribute defs.
###############################################################################

locals {
  # The five GSIs on the main CRM tables. hash/range keys map to the
  # GSI<n>PK / GSI<n>SK attributes.
  crm_gsis = [for i in range(1, 6) : {
    name  = "GSI${i}"
    hash  = "GSI${i}PK"
    range = "GSI${i}SK"
  }]
}

resource "aws_dynamodb_table" "crm" {
  for_each = toset(var.crm_table_names)

  name         = each.value
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  # GSI1..GSI5 key attributes.
  dynamic "attribute" {
    for_each = local.crm_gsis
    content {
      name = attribute.value.hash
      type = "S"
    }
  }
  dynamic "attribute" {
    for_each = local.crm_gsis
    content {
      name = attribute.value.range
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = local.crm_gsis
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.hash
      range_key       = global_secondary_index.value.range
      projection_type = "ALL"
    }
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  tags = {
    Role = "icc-crm"
  }
}

resource "aws_dynamodb_table" "audit" {
  for_each = toset(var.audit_table_names)

  name         = each.value
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  tags = {
    Role = "icc-crm-audit"
  }
}

output "crm_table_arns" {
  description = "ARNs of the CRM tables (keyed by name)."
  value       = { for k, t in aws_dynamodb_table.crm : k => t.arn }
}

output "audit_table_arns" {
  description = "ARNs of the audit tables (keyed by name)."
  value       = { for k, t in aws_dynamodb_table.audit : k => t.arn }
}
