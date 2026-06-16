###############################################################################
# Security Hub control SSM.6
# - SSM Automation should have CloudWatch logging enabled.
#
# Composition (per region):
#   1. CMK that encrypts the destination log group, with a policy that allows
#      CloudWatch Logs in that region to encrypt and the SSM Automation role to
#      decrypt the data keys it needs at runtime.
#   2. CloudWatch Logs group /aws/ssm/automation, encrypted with the regional CMK.
#   3. aws_ssm_service_setting that points SSM Automation at the log group.
#
# Account-wide (created once, used by all three regions):
#   4. IAM role AcceleratorBaseline-SSMAutomationLogging, trusted by ssm.amazonaws.com,
#      with a permissions policy enumerating the three log group ARNs explicitly.
#
# Why CMKs instead of the AWS-managed key:
#   Auditors prefer customer-managed encryption for traceability, rotation
#   control, and key-policy review. The cost is ~$1/region/month per account.
###############################################################################

###############################################################################
# 1. KMS keys (one per region)
###############################################################################

data "aws_iam_policy_document" "automation_logs_kms_use1" {
  statement {
    sid       = "AllowAccountRootAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogsEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.regions.use1}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.automation_log_group_kms_context_arns.use1]
    }
  }

  statement {
    sid    = "AllowSSMAutomationRoleUse"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.automation_logging.arn]
    }
  }
}

data "aws_iam_policy_document" "automation_logs_kms_use2" {
  statement {
    sid       = "AllowAccountRootAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogsEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.regions.use2}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.automation_log_group_kms_context_arns.use2]
    }
  }

  statement {
    sid    = "AllowSSMAutomationRoleUse"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.automation_logging.arn]
    }
  }
}

data "aws_iam_policy_document" "automation_logs_kms_usw2" {
  statement {
    sid       = "AllowAccountRootAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogsEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.regions.usw2}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.automation_log_group_kms_context_arns.usw2]
    }
  }

  statement {
    sid    = "AllowSSMAutomationRoleUse"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.automation_logging.arn]
    }
  }
}

resource "aws_kms_key" "automation_logs_use1" {
  provider                = aws.use1
  description             = "CMK for SSM Automation CloudWatch logs (us-east-1)"
  deletion_window_in_days = var.automation_log_kms_deletion_window
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.automation_logs_kms_use1.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "automation_logs_use1" {
  provider      = aws.use1
  name          = "alias/security-baseline-ssm-automation-logs"
  target_key_id = aws_kms_key.automation_logs_use1.id
}

resource "aws_kms_key" "automation_logs_use2" {
  provider                = aws.use2
  description             = "CMK for SSM Automation CloudWatch logs (us-east-2)"
  deletion_window_in_days = var.automation_log_kms_deletion_window
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.automation_logs_kms_use2.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "automation_logs_use2" {
  provider      = aws.use2
  name          = "alias/security-baseline-ssm-automation-logs"
  target_key_id = aws_kms_key.automation_logs_use2.id
}

resource "aws_kms_key" "automation_logs_usw2" {
  provider                = aws.usw2
  description             = "CMK for SSM Automation CloudWatch logs (us-west-2)"
  deletion_window_in_days = var.automation_log_kms_deletion_window
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.automation_logs_kms_usw2.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "automation_logs_usw2" {
  provider      = aws.usw2
  name          = "alias/security-baseline-ssm-automation-logs"
  target_key_id = aws_kms_key.automation_logs_usw2.id
}

###############################################################################
# 2. CloudWatch log groups (one per region, encrypted with the regional CMK)
###############################################################################

resource "aws_cloudwatch_log_group" "automation_use1" {
  provider          = aws.use1
  name              = local.automation_log_group_name
  retention_in_days = var.automation_log_retention_days
  kms_key_id        = aws_kms_key.automation_logs_use1.arn
  tags              = local.default_tags
}

resource "aws_cloudwatch_log_group" "automation_use2" {
  provider          = aws.use2
  name              = local.automation_log_group_name
  retention_in_days = var.automation_log_retention_days
  kms_key_id        = aws_kms_key.automation_logs_use2.arn
  tags              = local.default_tags
}

resource "aws_cloudwatch_log_group" "automation_usw2" {
  provider          = aws.usw2
  name              = local.automation_log_group_name
  retention_in_days = var.automation_log_retention_days
  kms_key_id        = aws_kms_key.automation_logs_usw2.arn
  tags              = local.default_tags
}

###############################################################################
# 3. IAM role for SSM Automation (account-wide, IAM is global)
###############################################################################

data "aws_iam_policy_document" "automation_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "automation_logging" {
  statement {
    sid    = "WriteAutomationLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      local.automation_log_group_arns.use1,
      local.automation_log_group_arns.use2,
      local.automation_log_group_arns.usw2,
    ]
  }
}

resource "aws_iam_role" "automation_logging" {
  name               = local.automation_role_name
  assume_role_policy = data.aws_iam_policy_document.automation_assume.json
  tags               = local.default_tags
}

resource "aws_iam_role_policy" "automation_logging" {
  name   = "AcceleratorBaseline-SSMAutomationLogging"
  role   = aws_iam_role.automation_logging.id
  policy = data.aws_iam_policy_document.automation_logging.json
}

###############################################################################
# Note on SSM.6 (SSM Automation should have CloudWatch logging enabled)
#
# AWS does not expose ssm/automation/cloudwatch-log-group as an account-level
# SSM service setting. The Console "Automation > Preferences" UI you may see
# does NOT persist a service setting; it only sets a default that applies at
# runbook invocation time and is not stored as account state.
#
# Consequence: there is no aws_ssm_service_setting resource that can satisfy
# Inspector control SSM.6. Logging must be specified per-runbook by passing
# CloudWatchOutputEnabled / CloudWatchLogGroupName when starting an Automation
# execution (or in the Run Command CloudWatch output config).
#
# What this module still provides for that workflow:
#   - aws_kms_key per region (encrypts the log group)
#   - aws_cloudwatch_log_group "/aws/ssm/automation" per region
#   - aws_iam_role "AcceleratorBaseline-SSMAutomationLogging" with permission to
#     write to those log groups
#
# When you start an Automation execution, point it at:
#   - log group:    /aws/ssm/automation
#   - service role: arn:aws:iam::<account>:role/AcceleratorBaseline-SSMAutomationLogging
#
# The strategy doc reclassifies SSM.6 from "Terraform" to "Manual" with this
# runbook note. See:
#   .kiro/specs/security-hub-findings-remediation-strategy/design.md
###############################################################################
