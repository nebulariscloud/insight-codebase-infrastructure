###############################################################################
# Developer hub role in SharedServices
#
# Identity Center permission sets land users in SharedServices with a base
# permission set ("TerraformDeveloper"). That permission set should grant
# nothing in SharedServices itself except: state backend access + ability to
# AssumeRole into TerraformExecution in any spoke.
#
# This role isn't strictly necessary - the permission set could carry these
# inline policies directly. Keeping the policies as a managed customer policy
# attached to the permission set means changes to the policy don't require
# touching Identity Center.
#
# After this runs:
#   1. In Identity Center console (SharedServices, since it's delegated admin)
#      create permission set "TerraformDeveloper".
#   2. Attach customer-managed policy "TerraformDeveloperHubAccess" (created here).
#   3. Assign the permission set to the appropriate group in SharedServices.
#
# A read-only flavor "TerraformReadOnly" can attach the same policy minus
# state writes; for now it's documented in README and left as a manual setup.
###############################################################################

data "aws_iam_policy_document" "dev_hub_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "ReadWriteState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid    = "UseStateKms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.state.arn]
  }

  statement {
    sid    = "Locks"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.locks.arn]
  }

  statement {
    sid       = "AssumeTerraformExecutionInAnySpoke"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:${local.partition}:iam::*:role/TerraformExecution"]
  }

  statement {
    sid    = "ReadSsmInTooling"
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BasicReadOnly"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:GetRole",
      "iam:GetUser",
      "ec2:DescribeRegions",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "dev_hub_access" {
  name        = "TerraformDeveloperHubAccess"
  description = "Attach to the TerraformDeveloper Identity Center permission set in SharedServices."
  policy      = data.aws_iam_policy_document.dev_hub_access.json
}

###############################################################################
# Read-only variant - same minus state writes
###############################################################################

data "aws_iam_policy_document" "readonly_hub_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadStateOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid    = "DecryptStateOnly"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.state.arn]
  }

  # Read-only TF still needs lock table read for `terraform plan` to inspect
  # current locks; no put/delete.
  statement {
    sid    = "LockTableRead"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.locks.arn]
  }

  statement {
    sid       = "AssumeTerraformExecutionInAnySpoke"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:${local.partition}:iam::*:role/TerraformExecution"]
  }

  statement {
    sid    = "ReadSsmInTooling"
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "readonly_hub_access" {
  name        = "TerraformReadOnlyHubAccess"
  description = "Attach to the TerraformReadOnly Identity Center permission set in SharedServices."
  policy      = data.aws_iam_policy_document.readonly_hub_access.json
}

output "developer_policy_arn" {
  description = "Attach to the TerraformDeveloper Identity Center permission set."
  value       = aws_iam_policy.dev_hub_access.arn
}

output "readonly_policy_arn" {
  description = "Attach to the TerraformReadOnly Identity Center permission set."
  value       = aws_iam_policy.readonly_hub_access.arn
}
