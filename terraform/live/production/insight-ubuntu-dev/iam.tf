###############################################################################
# Dedicated instance role for insight-ubuntu-dev. Mirror of the prod leaf.
###############################################################################

data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-instance-role"
  description        = "Instance role for ${var.name}. SSM + CloudWatch Agent + Session Manager KMS."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "session_manager_kms" {
  statement {
    sid       = "SessionManagerLogsKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.session_manager_logs.target_key_arn]
  }
}

resource "aws_iam_role_policy" "session_manager_kms" {
  name   = "session-manager-kms"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.session_manager_kms.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.this.name
}

###############################################################################
# ICC CRM data-access policy
#
# The ICC app runs on this box and needs runtime access to the data plane
# provisioned by the `icc-crm-backend` leaf: DynamoDB (CRM + audit tables),
# the two S3 document buckets, and the Cognito user pool. This replaces the
# vendor script's hand-run `iam put-role-policy icc-data-access`.
#
# ARNs are constructed from the fixed resource names (see icc-crm-backend)
# rather than read via remote state, to keep this leaf's plan independent of
# the backend leaf's apply order. Toggle with var.enable_icc_data_access.
###############################################################################

data "aws_iam_policy_document" "icc_data_access" {
  count = var.enable_icc_data_access ? 1 : 0

  statement {
    sid = "DynamoDB"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:DescribeTable",
    ]
    resources = flatten([
      for t in var.icc_dynamodb_table_names : [
        "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${t}",
        "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${t}/index/*",
      ]
    ])
  }

  statement {
    sid = "S3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = flatten([
      for b in var.icc_document_bucket_names : [
        "arn:aws:s3:::${b}",
        "arn:aws:s3:::${b}/*",
      ]
    ])
  }

  statement {
    sid = "Cognito"
    actions = [
      "cognito-idp:Admin*",
      "cognito-idp:List*",
      "cognito-idp:Describe*",
      "cognito-idp:Get*",
    ]
    # Pool ID is created in the icc-crm-backend leaf; scope to this account's
    # user pools in-region rather than coupling to that leaf's state.
    resources = ["arn:aws:cognito-idp:${var.region}:${var.account_id}:userpool/*"]
  }
}

resource "aws_iam_role_policy" "icc_data_access" {
  count = var.enable_icc_data_access ? 1 : 0

  name   = "icc-data-access"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.icc_data_access[0].json
}

output "instance_role_arn" {
  description = "ARN of the instance role."
  value       = aws_iam_role.this.arn
}
