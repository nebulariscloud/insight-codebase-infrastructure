###############################################################################
# Dedicated instance role for the SFTP server.
#
# Why not reuse LZA's EC2-Default-SSM-Role:
#   - It's shared by every EC2 in this account, so any S3 grant we add to it
#     would leak the amex-recordings bucket to unrelated workloads.
#   - It's tagged Accelerator=AWSAccelerator, which the lza-core-guardrails-2
#     SCP uses to deny iam:PutRolePolicy / iam:AttachRolePolicy from
#     non-LZA principals. Terraform literally cannot mutate it.
#
# This role mirrors the SSM + CloudWatch Agent permissions LZA grants the
# default role, plus a tightly-scoped inline policy for the amex recordings
# bucket. The role name and absence of an Accelerator tag keep it inside
# the TerraformExecution allow-list (NotResource: AWSAccelerator-*).
###############################################################################

# LZA's `sessionManager.sendToCloudWatchLogs = true` (global-config.yaml)
# turns on KMS-encrypted Session Manager streaming. The CMK is created by
# LZA per account/region with the alias below. Without kms:Decrypt +
# kms:GenerateDataKey on this CMK, `aws ssm start-session` fails with
# "AccessDeniedException: User ... is not authorized to perform:
# kms:Decrypt on resource: arn:aws:kms:...:key/...".
#
# LZA wires this permission onto its own EC2-Default-SSM-Role via
# `sessionManager.attachPolicyToIamRoles`. Our dedicated instance role
# isn't on that list (and shouldn't be — keeping it Terraform-managed
# avoids the LZA-owned-role mutation problem), so we grant the same
# permission directly here.
data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

locals {
  amex_bucket_name = var.amex_bucket_name != "" ? var.amex_bucket_name : "amex-recordings-prod-${var.account_id}"
  amex_bucket_arn  = "arn:aws:s3:::${local.amex_bucket_name}"
  # KMS key encrypting the amex-recordings bucket. Set in tfvars when the
  # bucket uses SSE-KMS with a customer-managed key. When empty, the role
  # gets no KMS grant (fine for SSE-S3 buckets).
  amex_bucket_kms_key_arn = var.amex_bucket_kms_key_arn
}

data "aws_iam_policy_document" "sftp_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sftp" {
  name               = "${var.name}-instance-role"
  description        = "Instance role for the SFTP server. SSM + CloudWatch Agent + scoped amex-recordings bucket access."
  assume_role_policy = data.aws_iam_policy_document.sftp_assume.json
}

# Mirror the AWS-managed policies LZA puts on EC2-Default-SSM-Role so SSM
# Session Manager and the CloudWatch Agent keep working unchanged.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.sftp.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.sftp.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Scoped grant: read/write/list on the amex recordings bucket only.
# PutObjectRetention is included because the bucket has Object Lock enabled
# and producers may set per-object retention at PutObject time (see the
# amex-recordings leaf README).
data "aws_iam_policy_document" "amex_bucket" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.amex_bucket_arn]
  }

  statement {
    sid = "ReadWriteObjects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectAttributes",
      "s3:GetObjectTagging",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectTagging",
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.amex_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "amex_bucket" {
  name   = "amex-recordings-access"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.amex_bucket.json
}

# When the bucket uses SSE-KMS with a customer-managed key, every
# PutObject server-side calls kms:GenerateDataKey and every GetObject
# calls kms:Decrypt against that key. Without these grants the EC2 sees
# 403/EPERM at close time. This statement is gated on the variable so
# SSE-S3 buckets don't get an unnecessary KMS grant.
data "aws_iam_policy_document" "amex_bucket_kms" {
  count = local.amex_bucket_kms_key_arn == "" ? 0 : 1

  statement {
    sid = "S3KmsDataKey"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [local.amex_bucket_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "amex_bucket_kms" {
  count = local.amex_bucket_kms_key_arn == "" ? 0 : 1

  name   = "amex-recordings-kms"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.amex_bucket_kms[0].json
}

# Session Manager KMS permissions (see comment on data.aws_kms_alias above).
data "aws_iam_policy_document" "session_manager_kms" {
  statement {
    sid       = "SessionManagerLogsKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.session_manager_logs.target_key_arn]
  }
}

resource "aws_iam_role_policy" "session_manager_kms" {
  name   = "session-manager-kms"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.session_manager_kms.json
}

resource "aws_iam_instance_profile" "sftp" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.sftp.name
}

output "instance_role_name" {
  description = "Name of the instance role attached to the SFTP server."
  value       = aws_iam_role.sftp.name
}

output "instance_role_arn" {
  description = "ARN of the instance role attached to the SFTP server."
  value       = aws_iam_role.sftp.arn
}
