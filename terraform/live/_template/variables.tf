variable "account_name" {
  description = "Spoke account name as it appears in accounts-config.yaml (e.g. Perimeter, SharedServices, Production, PCI)."
  type        = string
}

variable "stack_name" {
  description = "Short stack name. Used in tags and session names."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}
