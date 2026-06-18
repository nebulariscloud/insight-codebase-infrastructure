###############################################################################
# Dedicated instance role for the Claro SFTP server.
#
# Why not reuse LZA's EC2-Default-SSM-Role:
#   - It's shared by every EC2 in this account, so any S3 grant we add to it
#     would leak the claro-recordings bucket to unrelated workloads.
#   - It's tagged Accelerator=AWSAccelerator, which the lza-core-guardrails-2
#     SCP uses to deny iam:PutRolePolicy / iam:AttachRolePolicy from
#     non-LZA principals. Terraform literally cannot mutate it.
#
# This role mirrors the SSM + CloudWatch Agent permissions LZA grants the
# default role, plus a tightly-scoped inline policy for the claro recordings
# bucket. The role name and absence of an Accelerator tag keep it inside
# the TerraformExecution allow-list (NotResource: AWSAccelerator-*).
#
# Same shape as the sibling `sftp-server` leaf's iam.tf - keep them in
# lockstep when policy changes are needed.
###############################################################################

locals {
  claro_bucket_name = var.claro_bucket_name != "" ? var.claro_bucket_name : "claro-recordings-prod-${var.account_id}"
  claro_bucket_arn  = "arn:aws:s3:::${local.claro_bucket_name}"
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
  description        = "Instance role for the Claro SFTP server. SSM + CloudWatch Agent + scoped claro-recordings bucket access."
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

# Scoped grant: read/write/list on the claro recordings bucket only.
# PutObjectRetention is included because the bucket has Object Lock enabled
# and producers may set per-object retention at PutObject time (see the
# claro-recordings leaf README).
data "aws_iam_policy_document" "claro_bucket" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.claro_bucket_arn]
  }

  statement {
    sid = "ReadWriteObjects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.claro_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "claro_bucket" {
  name   = "claro-recordings-access"
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.claro_bucket.json
}

resource "aws_iam_instance_profile" "sftp" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.sftp.name
}

output "instance_role_name" {
  description = "Name of the instance role attached to the Claro SFTP server."
  value       = aws_iam_role.sftp.name
}

output "instance_role_arn" {
  description = "ARN of the instance role attached to the Claro SFTP server."
  value       = aws_iam_role.sftp.arn
}
