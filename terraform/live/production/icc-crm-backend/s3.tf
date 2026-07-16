###############################################################################
# S3 — ICC document storage (prod + dev)
#
# Private buckets (full public-access-block), SSE-S3, versioning, TLS-only,
# and a CORS policy allowing the frontend origins to PUT/GET/POST directly
# (presigned-URL upload/download from the SPA). Mirrors the vendor's script,
# plus versioning + a TLS-only bucket policy which the script omitted.
###############################################################################

resource "aws_s3_bucket" "docs" {
  for_each = toset(var.document_bucket_names)
  bucket   = each.value

  tags = {
    Role = "icc-documents"
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  for_each = aws_s3_bucket.docs

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "docs" {
  for_each = aws_s3_bucket.docs

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "docs" {
  for_each = aws_s3_bucket.docs

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  for_each = aws_s3_bucket.docs

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_cors_configuration" "docs" {
  for_each = aws_s3_bucket.docs

  bucket = each.value.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = var.cors_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# TLS-only access. Read/write authz lives in IAM (the instance role); this
# just rejects anything that isn't HTTPS.
resource "aws_s3_bucket_policy" "docs" {
  for_each = aws_s3_bucket.docs

  bucket = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          each.value.arn,
          "${each.value.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.docs]
}

output "document_bucket_names" {
  description = "Names of the document buckets."
  value       = [for b in aws_s3_bucket.docs : b.id]
}

output "document_bucket_arns" {
  description = "ARNs of the document buckets (keyed by name)."
  value       = { for k, b in aws_s3_bucket.docs : k => b.arn }
}
