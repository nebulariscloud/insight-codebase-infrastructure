variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the spoke."
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

variable "alb_region" {
  description = "Region the IngressALB lives in. Different from the Global Accelerator control-plane region (us-west-2)."
  type        = string
  default     = "us-east-2"
}

variable "alb_name" {
  description = "Name of the existing ALB to put behind Global Accelerator. Looked up via data.aws_lb."
  type        = string
}
