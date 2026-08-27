###############################################################################
# Dedicated instance role for the F9 SFTP server.
#
# Why not reuse LZA's EC2-Default-SSM-Role:
#   - It's shared by every EC2 in this account, so any S3 grant we add to it
#     would leak the f9-recordings bucket to unrelated workloads.
#   - It's tagged Accelerator=AWSAccelerator, which the lza-core-guardrails-2
#     SCP uses to deny iam:PutRolePolicy / iam:AttachRolePolicy from
#     non-LZA principals. Terraform literally cannot mutate it.
#
# This role mirrors the SSM + CloudWatch Agent permissions LZA grants the
# default role, plus a tightly-scoped inline policy for the f9 recordings
# bucket. The role name and absence of an Accelerator tag keep it inside
# the TerraformExecution allow-list (NotResource: AWSAccelerator-*).
#
# Same shape as the sibling `sftp-server` / `sftp-server-claro` leaves'
# iam.tf - keep them in lockstep when policy changes are needed.
###############################################################################

# LZA's `sessionManager.sendToCloudWatchLogs = true` (global-config.yaml)
# turns on KMS-encrypted Session Manager streaming. Our dedicated instance
# role isn't on LZA's `sessionManager.attachPolicyToIamRoles` list (which
# only covers EC2-Default-SSM-Role), so we grant kms:Decrypt +
# kms:GenerateDataKey directly here. Without it, `aws ssm start-session`
# fails with "AccessDeniedException: ... is not authorized to perform:
# kms:Decrypt".
data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

locals {
  f9_bucket_name = var.f9_bucket_name != "" ? var.f9_bucket_name : "f9-recordings-prod-${var.account_id}"
  f9_bucket_arn  = "arn:aws:s3:::${local.f9_bucket_name}"
  # KMS key encrypting the f9-recordings bucket. Set in tfvars when the
  # bucket uses SSE-KMS with a customer-managed key. When empty, the role
  # gets no KMS grant (fine for SSE-S3 buckets).
  f9_bucket_kms_key_arn = var.f9_bucket_kms_key_arn
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
  description        = "Instance role for the F9 SFTP server. SSM + CloudWatch Agent + scoped f9-recordings bucket access."
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

# Scoped grant: read/write/list on the f9 recordings bucket only.
# PutObjectRetention is included because the bucket has Object Lock enabled
# and producers may set per-object retention at PutObject time (see the
# f9-recordings leaf README).
data "aws_iam_policy_document" "f9_bucket" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.f9_bucket_arn]
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
    resources = ["${local.f9_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "f9_bucket" {
  name   = "f9-recordings-access"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.f9_bucket.json
}

# When the bucket uses SSE-KMS with a customer-managed key, every
# PutObject server-side calls kms:GenerateDataKey and every GetObject
# calls kms:Decrypt against that key. Without these grants the EC2 sees
# 403/EPERM at close time. This statement is gated on the variable so
# SSE-S3 buckets don't get an unnecessary KMS grant.
data "aws_iam_policy_document" "f9_bucket_kms" {
  count = local.f9_bucket_kms_key_arn == "" ? 0 : 1

  statement {
    sid = "S3KmsDataKey"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [local.f9_bucket_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "f9_bucket_kms" {
  count = local.f9_bucket_kms_key_arn == "" ? 0 : 1

  name   = "f9-recordings-kms"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.f9_bucket_kms[0].json
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
  description = "Name of the instance role attached to the F9 SFTP server."
  value       = aws_iam_role.sftp.name
}

output "instance_role_arn" {
  description = "ARN of the instance role attached to the F9 SFTP server."
  value       = aws_iam_role.sftp.arn
}
