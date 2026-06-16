###############################################################################
# Security Hub controls Inspector.1, Inspector.2, Inspector.3, Inspector.4
# - Amazon Inspector EC2 / ECR / Lambda code / Lambda standard scanning enabled.
#
# Wired as a feature flag, off by default. Turning it on requires:
#   - inspector_enabled         = true
#   - inspector_resource_types  = subset of EC2, ECR, LAMBDA, LAMBDA_CODE
#   - inspector_regions         = at least one region matching var.regions
#
# Until decision item D-1 lands, all three resources evaluate to count = 0.
###############################################################################

resource "aws_inspector2_enabler" "use1" {
  count    = local.inspector_active && contains(var.inspector_regions, var.regions.use1) ? 1 : 0
  provider = aws.use1

  account_ids    = [local.account_id]
  resource_types = var.inspector_resource_types
}

resource "aws_inspector2_enabler" "use2" {
  count    = local.inspector_active && contains(var.inspector_regions, var.regions.use2) ? 1 : 0
  provider = aws.use2

  account_ids    = [local.account_id]
  resource_types = var.inspector_resource_types
}

resource "aws_inspector2_enabler" "usw2" {
  count    = local.inspector_active && contains(var.inspector_regions, var.regions.usw2) ? 1 : 0
  provider = aws.usw2

  account_ids    = [local.account_id]
  resource_types = var.inspector_resource_types
}
