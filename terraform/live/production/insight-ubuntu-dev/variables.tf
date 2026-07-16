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
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "insight-ubuntu-dev"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.medium"
}

variable "vpc_id" {
  description = "Shared-prod VPC ID (vpc-04a8720d0ddb40713)."
  type        = string
}

variable "subnet_id" {
  description = "Shared-prod-app-a subnet (10.12.1.0/24)."
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    Optional static private IP inside the chosen subnet. Existing tenants
    in 10.12.1.0/24:
      10.12.1.50  - sftp-server
      10.12.1.51  - sftp-server-claro
      10.12.1.60  - moodle
      10.12.1.70  - insight-ubuntu-prod
      10.12.1.121 - wazuh
      10.12.1.174 - scriptcase-php-73
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size (gp3, encrypted)."
  type        = number
  default     = 30
}

variable "eice_security_group_id" {
  description = "Optional. EICE endpoint SG for fallback SSH access. Empty = SSM-only."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name. Empty = SSM-only access (recommended)."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# ICC CRM data-access grant (see iam.tf)
# ----------------------------------------------------------------------------

variable "enable_icc_data_access" {
  description = <<-EOT
    Attach the `icc-data-access` inline policy to this box's instance role,
    granting DynamoDB + S3 + Cognito access to the ICC CRM data plane
    provisioned by the icc-crm-backend leaf. The app runs on this box.
  EOT
  type        = bool
  default     = false
}

variable "icc_dynamodb_table_names" {
  description = "ICC DynamoDB table names to grant runtime access to. Must match the icc-crm-backend leaf."
  type        = list(string)
  default = [
    "icc-crm",
    "icc-crm-dev",
    "icc-crm-audit",
    "icc-crm-audit-dev",
  ]
}

variable "icc_document_bucket_names" {
  description = "ICC S3 document bucket names to grant runtime access to. Must match the icc-crm-backend leaf."
  type        = list(string)
  default = [
    "insight-icc-documents",
    "insight-icc-documents-dev",
  ]
}
