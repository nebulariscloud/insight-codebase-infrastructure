###############################################################################
# Claro recordings bucket (Production)
#
# S3 bucket for recording storage with:
#   - Object Lock enabled at create time (cannot be turned on later)
#   - Versioning enabled (required for Object Lock)
#   - SSE-S3 encryption by default
#   - Public access fully blocked
#   - Bucket-owner-enforced ACLs
#   - TLS-only access policy
#
# Default retention is OFF. Object Lock is enabled on the bucket so
# producers can apply per-object retention via the PutObject API. Flip
# var.enable_default_object_lock_retention to true if you want every
# object locked automatically on upload.
#
# Mirrors the sibling `amex-recordings` leaf - keep changes in lockstep.
###############################################################################

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "claro-recordings-prod-${var.account_id}"
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  # MUST be set at creation. AWS does not allow enabling Object Lock on an
  # existing bucket without filing a support ticket.
  object_lock_enabled = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Optional default retention. When this is configured, every PutObject
# without an explicit retention header inherits these settings.
resource "aws_s3_bucket_object_lock_configuration" "this" {
  count  = var.enable_default_object_lock_retention ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.default_object_lock_mode
      days = var.default_object_lock_days
    }
  }

  # Versioning must be live before this can attach.
  depends_on = [aws_s3_bucket_versioning.this]
}

# Lifecycle for non-current versions only. Current versions are protected
# by Object Lock; lifecycle won't expire locked objects.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.noncurrent_version_retention_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# TLS-only access. Read/write authz lives in IAM; this just rejects
# anything that isn't HTTPS.
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.this.arn,
          "${aws_s3_bucket.this.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

###############################################################################
# Outputs
###############################################################################

output "bucket_name" {
  description = "S3 bucket name."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "S3 bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional endpoint for the bucket."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}
