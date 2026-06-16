variable "account_name" {
  description = "Spoke account name. Used in tags and IAM session names."
  type        = string
  default     = "PCI"
}

variable "account_id" {
  description = <<-EOT
    Spoke account's 12-digit AWS account ID. If empty, the leaf falls back to
    reading var.account_id_ssm_path from SSM in SharedServices.
    Set this explicitly only if LZA has not published the SSM parameter yet.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.account_id == "" || can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be empty or a 12-digit AWS account ID."
  }
}

variable "account_id_ssm_path" {
  description = "SSM path in SharedServices that holds the spoke's account ID. Only used when account_id is empty."
  type        = string
  default     = "/accelerator/organization/account-ids/PCI"
}

variable "security_contact_phone_ssm_path" {
  description = "SSM SecureString path in SharedServices holding the SECURITY alternate contact phone."
  type        = string
  default     = "/security-baseline/security-contact-phone"
}

variable "security_contact_name" {
  description = "SECURITY alternate contact name shown to AWS."
  type        = string
  default     = "Alex Gonzalez"
}

variable "security_contact_email" {
  description = "SECURITY alternate contact email used by AWS for incident notifications."
  type        = string
  default     = "security@nebulariscloud.com"
}

variable "security_contact_title" {
  description = "SECURITY alternate contact title shown to AWS."
  type        = string
  default     = "CEO"
}
