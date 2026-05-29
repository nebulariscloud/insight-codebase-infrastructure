variable "name" {
  description = "Accelerator name."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to put behind Global Accelerator."
  type        = string
}

variable "alb_region" {
  description = "Region the ALB lives in. Different from the GA control-plane region (us-west-2)."
  type        = string
}

variable "listener_port_ranges" {
  description = "Listener port ranges. Default: 80 and 443."
  type = list(object({
    from_port = number
    to_port   = number
  }))
  default = [
    { from_port = 80, to_port = 80 },
    { from_port = 443, to_port = 443 },
  ]
}

variable "protocol" {
  description = "TCP or UDP."
  type        = string
  default     = "TCP"
  validation {
    condition     = contains(["TCP", "UDP"], var.protocol)
    error_message = "protocol must be TCP or UDP."
  }
}

variable "client_affinity" {
  description = "NONE or SOURCE_IP."
  type        = string
  default     = "NONE"
}

variable "client_ip_preservation" {
  description = "Preserve client IP through the accelerator (forwarded to the ALB target group)."
  type        = bool
  default     = true
}

variable "health_check_port" {
  description = "Port the accelerator probes on the ALB. Usually 80 even when traffic is 443."
  type        = number
  default     = 80
}

variable "health_check_interval_seconds" {
  description = "Health check interval. 10 or 30."
  type        = number
  default     = 30
}

variable "threshold_count" {
  description = "Consecutive failures before unhealthy."
  type        = number
  default     = 3
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
