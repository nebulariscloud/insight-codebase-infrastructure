###############################################################################
# WAF logging destination: S3 bucket + KMS CMK + (optional) attachment to
# existing Web ACLs.
#
# Why direct-to-S3 instead of Firehose:
#   - Firehose adds an SCP touchpoint (lza-core-guardrails-1 restricts
#     firehose Create/Delete/Update to AWSAccelerator-prefixed streams).
#   - WAF supports S3 as a first-class logging destination - no Firehose
#     needed. WAF writes one .gz object per partition per ~5 minutes.
#   - Storage + Athena query is the same pattern LZA already uses for
#     central logs.
#
# Why a Terraform-owned KMS key instead of the LZA accelerator-s3 key:
#   - terraform/README.md states: Terraform reads LZA outputs but does not
#     mutate LZA resources. Sharing the LZA key would require updating its
#     key policy from this module - that crosses the boundary.
#   - Cost is ~$1/region/month. Cheap, and isolates WAF logs cryptographically
#     from the rest of the central log estate.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  default_tags = merge(
    {
      ManagedBy = "Terraform"
      Module    = "waf-logs"
      Name      = var.name
    },
    var.tags,
  )
}

###############################################################################
# KMS key for WAF logs
###############################################################################

data "aws_iam_policy_document" "waf_logs_kms" {
  # Account root admin
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

  # The WAF logging service writes via an internal delivery role. The S3
  # bucket policy is what gates put-object; KMS just needs to allow the
  # account itself (so any principal in the account that holds s3:PutObject
  # on the bucket can encrypt with the key).
  #
  # WAF service principal: per AWS docs, when WAF logs to S3 it uses an
  # internal logging principal. Allow it to use the key for encrypt-only
  # actions, scoped via aws:SourceAccount.
  statement {
    sid    = "AllowWafLoggingDeliveryEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "waf_logs" {
  description             = "CMK encrypting the ${var.bucket_name} bucket holding WAF logs."
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.waf_logs_kms.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "waf_logs" {
  name          = "alias/waf-logs-${var.name}"
  target_key_id = aws_kms_key.waf_logs.id
}

###############################################################################
# S3 bucket
###############################################################################

resource "aws_s3_bucket" "waf_logs" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = local.default_tags
}

resource "aws_s3_bucket_ownership_controls" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.waf_logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  count  = var.log_retention_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    id     = "waf-logs-lifecycle"
    status = "Enabled"

    filter {} # apply to entire bucket

    transition {
      days          = var.transition_to_glacier_ir_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

###############################################################################
# Bucket policy - WAF logging service writes objects via the AWS Logs
# Delivery service. Standard pattern documented at:
# https://docs.aws.amazon.com/waf/latest/developerguide/logging-s3.html
###############################################################################

data "aws_iam_policy_document" "waf_logs_bucket" {
  # Service-principal write permission, scoped to this account + region.
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.waf_logs.arn}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # The delivery service also calls GetBucketAcl to validate the destination.
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.waf_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # Defense-in-depth: deny any non-TLS request.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.waf_logs.arn,
      "${aws_s3_bucket.waf_logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  policy = data.aws_iam_policy_document.waf_logs_bucket.json

  depends_on = [
    aws_s3_bucket_public_access_block.waf_logs,
  ]
}

###############################################################################
# Optional: attach the bucket as a logging destination to existing Web ACLs.
#
# aws_wafv2_web_acl_logging_configuration is a separate resource from
# aws_wafv2_web_acl, so attaching here does NOT modify the Web ACL itself.
# This lets us turn on logging for the CFN-managed Web ACLs (ingress-alb-waf,
# scriptcase-lb-waf) without crossing the LZA-vs-Terraform ownership line.
###############################################################################

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  for_each = toset(var.attach_to_web_acl_arns)

  resource_arn = each.value
  log_destination_configs = [
    aws_s3_bucket.waf_logs.arn,
  ]

  dynamic "redacted_fields" {
    for_each = toset(var.redacted_headers)
    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }

  depends_on = [
    aws_s3_bucket_policy.waf_logs,
  ]
}
