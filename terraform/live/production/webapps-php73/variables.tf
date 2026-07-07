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
  description = "AWS region the server lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Instance
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "webapps-php73"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is t3a.micro; kept the same."
  type        = string
  default     = "t3a.micro"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, copied+re-encrypted from the source-tenant webapps
    php7.3 AMI. Source root volume is ENCRYPTED with a customer CMK
    (6e7aced8-e4e6-4060-8b71-b00099d5412f) — that CMK must be shared to
    Production before the cross-account copy (see README). Placeholder until done.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = "shared-prod VPC ID in us-east-2."
  type        = string
}

variable "subnet_id" {
  description = "shared-prod app subnet ID (app-a or app-b). Private; the ALB targets the private IP over TGW."
  type        = string
}

variable "private_ip" {
  description = "Optional static private IP inside the chosen app subnet. Empty = AWS picks."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name for SSH admin access. Empty = SSM-only."
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 40 GiB; match it."
  type        = number
  default     = 40
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves the LZA EBS key."
  type        = string
  default     = ""
}

variable "app_ports" {
  description = "TCP ports the webapp serves, allowed inbound from the ingress VPC CIDR only."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_vpc_cidr" {
  description = "CIDR of the perimeter ingress VPC. The instance SG only allows the app ports from this range."
  type        = string
  default     = "10.0.0.0/20"
}

variable "eice_security_group_id" {
  description = "Optional. EC2 Instance Connect Endpoint SG ID in shared-prod, to allow admin SSH via EICE. Empty to skip."
  type        = string
  default     = ""
}
