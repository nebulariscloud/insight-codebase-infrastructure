###############################################################################
# GitHub Actions OIDC provider + role
#
# Lets GitHub Actions assume a role in SharedServices with no long-lived keys.
# The role here only does two things:
#   1. Read/write Terraform state in the state bucket.
#   2. AssumeRole into TerraformExecution in any spoke.
#
# All actual AWS work happens after the second hop, governed by
# terraform-execution-policy.json.
###############################################################################

# Thumbprint is GitHub's, published by AWS:
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

###############################################################################
# Trust policy: only the listed repos, only main branch (or PR / environment)
###############################################################################

locals {
  # Allow main branch pushes for apply, plus pull_request and environment refs
  # for plan-only flows. Tags and other branches are intentionally excluded.
  github_trust_subjects = flatten([
    for repo in var.github_repos : [
      "repo:${repo}:ref:refs/heads/main",
      "repo:${repo}:pull_request",
      "repo:${repo}:environment:production",
    ]
  ])
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_trust_subjects
    }
  }
}

###############################################################################
# Role: GitHubActions-Terraform
###############################################################################

resource "aws_iam_role" "github_actions" {
  name                 = "GitHubActions-Terraform"
  description          = "Assumed by GitHub Actions via OIDC. Chains into TerraformExecution in spokes."
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

# State backend access
data "aws_iam_policy_document" "state_access" {
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
}

# AssumeRole chain into spokes
data "aws_iam_policy_document" "spoke_assume" {
  statement {
    sid       = "AssumeTerraformExecutionInAnySpoke"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:${local.partition}:iam::*:role/TerraformExecution"]
  }

  # Allow reading account IDs and other LZA-published values from SSM in the
  # tooling account itself. (Remote spokes use the assumed role for this.)
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

resource "aws_iam_role_policy" "github_actions_state" {
  name   = "state-backend-access"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy" "github_actions_spoke" {
  name   = "spoke-assume"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.spoke_assume.json
}

###############################################################################
# Outputs
###############################################################################

output "github_oidc_provider_arn" {
  description = "OIDC provider ARN. Reuse if adding more roles for GitHub Actions later."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_role_arn" {
  description = "Pass this to aws-actions/configure-aws-credentials@v4 in your workflow."
  value       = aws_iam_role.github_actions.arn
}
