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

variable "nlb_name" {
  description = "Name of the existing NLB to put behind Global Accelerator on 1514-1515. Looked up via data.aws_lb."
  type        = string
  default     = "wazuh-nlb"
}

variable "agent_event_port" {
  description = "Wazuh agent events port (TCP). Default 1514. Becomes the start of the GA listener port range."
  type        = number
  default     = 1514
}

variable "agent_enroll_port" {
  description = "Wazuh agent enrollment port (TCP). Default 1515. Becomes the end of the GA listener port range."
  type        = number
  default     = 1515
}

variable "syslog_port" {
  description = <<-EOT
    Wazuh syslog input port (UDP). Default 514. Drives a dedicated UDP
    listener on the same accelerator (GA listeners are single-protocol,
    so this can't share the TCP listener that handles 1514/1515).
  EOT
  type        = number
  default     = 514
}
