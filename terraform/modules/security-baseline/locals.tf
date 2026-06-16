locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Single source of truth for the SSM Automation log group name across regions.
  automation_log_group_name = "/aws/ssm/automation"

  # Single source of truth for the IAM role SSM Automation assumes to write logs.
  automation_role_name = "AcceleratorBaseline-SSMAutomationLogging"

  default_tags = merge(
    {
      ManagedBy = "Terraform"
      Module    = "security-baseline"
      Stack     = "security-baseline"
      Account   = var.account_name
    },
    var.tags,
  )

  # Inspector is only "active" when the master flag is on AND both region and
  # resource-type lists are non-empty. Validates the matrix Inspector requires.
  inspector_active = (
    var.inspector_enabled
    && length(var.inspector_resource_types) > 0
    && length(var.inspector_regions) > 0
  )

  # Pre-compute the per-region log group ARNs so the IAM permissions policy can
  # enumerate them explicitly (no wildcards on Resource).
  automation_log_group_arns = {
    use1 = "arn:${local.partition}:logs:${var.regions.use1}:${local.account_id}:log-group:${local.automation_log_group_name}:*"
    use2 = "arn:${local.partition}:logs:${var.regions.use2}:${local.account_id}:log-group:${local.automation_log_group_name}:*"
    usw2 = "arn:${local.partition}:logs:${var.regions.usw2}:${local.account_id}:log-group:${local.automation_log_group_name}:*"
  }
}
