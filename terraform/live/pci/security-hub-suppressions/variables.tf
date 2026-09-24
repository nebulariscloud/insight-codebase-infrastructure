variable "account_name" {
  description = "Spoke account name (used in tags and session names)."
  type        = string
  default     = "PCI"
}

variable "account_id" {
  description = <<-EOT
    Spoke account's 12-digit AWS account ID. If empty, the provider falls back
    to reading var.account_id_ssm_path from SSM in SharedServices.
    Set this explicitly until LZA publishes /accelerator/organization/account-ids/*.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.account_id == "" || can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be empty or a 12-digit AWS account ID."
  }
}

variable "account_id_ssm_path" {
  description = "SSM path in SharedServices that holds the PCI account ID. Only used when account_id is empty."
  type        = string
  default     = "/accelerator/organization/account-ids/PCI"
}
