variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Production spoke."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "stack_name" {
  description = "Short stack name."
  type        = string
  default     = "icc-crm-backend"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# DynamoDB
# ----------------------------------------------------------------------------

variable "crm_table_names" {
  description = <<-EOT
    The two single-table CRM tables (prod + dev). Each gets PK/SK plus five
    GSIs (GSI1..GSI5, all ProjectionType ALL), PAY_PER_REQUEST. Order does not
    matter; names must be globally unique within the account+region.
  EOT
  type        = list(string)
  default     = ["icc-crm", "icc-crm-dev"]
}

variable "audit_table_names" {
  description = <<-EOT
    The two audit tables (prod + dev). Each gets PK/SK plus a single GSI (GSI1,
    ProjectionType ALL), PAY_PER_REQUEST.
  EOT
  type        = list(string)
  default     = ["icc-crm-audit", "icc-crm-audit-dev"]
}

variable "point_in_time_recovery" {
  description = "Enable PITR on all four tables. On for prod data safety; the vendor's script did not set it, but it's a cheap, recommended default."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# S3 document buckets
# ----------------------------------------------------------------------------

variable "document_bucket_names" {
  description = <<-EOT
    The two private document-storage buckets (prod + dev). Globally unique.
    CORS + public-access-block applied to both.
  EOT
  type        = list(string)
  default     = ["insight-icc-documents", "insight-icc-documents-dev"]
}

variable "cors_allowed_origins" {
  description = <<-EOT
    Frontend origins allowed to upload/download documents directly to S3.
    Update when the frontend URL changes. Methods GET/PUT/POST, all headers,
    ETag exposed, 1h max-age — mirrors the vendor's script.
  EOT
  type        = list(string)
  default = [
    "http://localhost:3000",
    "https://update-ventas-productos.d30759srcd7j8q.amplifyapp.com",
  ]
}

# ----------------------------------------------------------------------------
# Cognito
# ----------------------------------------------------------------------------

variable "user_pool_name" {
  description = "Cognito user pool name. Users are imported separately (not managed here)."
  type        = string
  default     = "icc-users"
}

variable "app_client_name" {
  description = "Cognito app client name (public SPA client, no secret)."
  type        = string
  default     = "icc-web"
}

variable "access_token_validity_minutes" {
  description = "Access token lifetime in minutes."
  type        = number
  default     = 60
}

variable "id_token_validity_minutes" {
  description = "ID token lifetime in minutes."
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Refresh token lifetime in days."
  type        = number
  default     = 5
}
