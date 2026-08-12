variable "name" {
  description = "ALB name. Becomes the Name tag and the LB resource name. Must be <=32 chars, lowercase, hyphens."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase, start/end alphanumeric, max 32 chars."
  }
}

variable "vpc_id" {
  description = "VPC where the ALB lives. Read from /accelerator/network/vpc/<name>/id."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnets for the ALB. At least two AZs."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An ALB requires at least two subnets in different AZs."
  }
}

variable "scheme" {
  description = "internet-facing or internal."
  type        = string
  default     = "internet-facing"
  validation {
    condition     = contains(["internet-facing", "internal"], var.scheme)
    error_message = "scheme must be internet-facing or internal."
  }
}

variable "ingress_cidrs" {
  description = "CIDRs allowed inbound to the ALB on 80/443. Defaults to the internet for internet-facing ALBs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "egress_cidrs" {
  description = "CIDRs the ALB can reach on the target port. Default 10.0.0.0/8 (private RFC1918 inside the org)."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "target_port" {
  description = "Backend port the targets listen on."
  type        = number
}

variable "target_protocol" {
  description = "Protocol used to talk to backends."
  type        = string
  default     = "HTTP"
  validation {
    condition     = contains(["HTTP", "HTTPS"], var.target_protocol)
    error_message = "target_protocol must be HTTP or HTTPS."
  }
}

variable "target_type" {
  description = "Target group target_type. 'ip' supports cross-VPC targets via TGW (typical for hub LB)."
  type        = string
  default     = "ip"
  validation {
    condition     = contains(["instance", "ip", "lambda", "alb"], var.target_type)
    error_message = "target_type must be instance, ip, lambda, or alb."
  }
}

variable "target_ids" {
  description = "Optional list of targets (instance IDs or IPs) to register up-front. Leave empty to register out-of-band."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "HTTP health check path."
  type        = string
  default     = "/health"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy, e.g. '200' or '200,302'."
  type        = string
  default     = "200"
}

variable "health_check_interval" {
  description = "Health check interval seconds."
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Health check timeout seconds."
  type        = number
  default     = 10
}

variable "healthy_threshold" {
  description = "Consecutive successes to mark healthy."
  type        = number
  default     = 3
}

variable "unhealthy_threshold" {
  description = "Consecutive failures to mark unhealthy."
  type        = number
  default     = 3
}

variable "deregistration_delay" {
  description = "Seconds to drain on deregistration."
  type        = number
  default     = 30
}

variable "certificate_arn" {
  description = "ACM cert ARN for HTTPS listener. Empty disables HTTPS (HTTP-only listener)."
  type        = string
  default     = ""
}

variable "ssl_policy" {
  description = "TLS policy on the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "access_logs_bucket" {
  description = "S3 bucket for access logs. Leave empty to disable. LZA pattern: aws-accelerator-elb-access-logs-<account-id>-<region>."
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "Prefix inside the access logs bucket."
  type        = string
  default     = ""
}

variable "cross_zone_load_balancing" {
  description = "Cross-zone LB. Disable to reduce cross-AZ data transfer when targets are in another VPC via TGW."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Deletion protection on the ALB. Strongly recommended for prod."
  type        = bool
  default     = true
}

variable "drop_invalid_header_fields" {
  description = "Drop invalid HTTP headers at the LB. Recommended."
  type        = bool
  default     = true
}

variable "desync_mitigation_mode" {
  description = "monitor | defensive | strictest. defensive is the AWS default best-practice."
  type        = string
  default     = "defensive"
}

variable "idle_timeout" {
  description = "Idle timeout in seconds."
  type        = number
  default     = 60
}

variable "enable_waf" {
  description = <<-EOT
    Whether to create the WAFv2 Web ACL association for this ALB.

    Must be a plain bool rather than being inferred from waf_web_acl_arn,
    because it drives `count` and therefore has to be known at PLAN time. The
    ARN usually is not — the documented pattern wires it to a Web ACL created
    in the same apply (`waf_web_acl_arn = module.waf.web_acl_arn`), which is
    unknown until that Web ACL exists.

    Set BOTH together:

      enable_waf      = true
      waf_web_acl_arn = module.waf.web_acl_arn
  EOT
  type        = bool
  default     = false
}

variable "waf_web_acl_arn" {
  description = <<-EOT
    WAF Web ACL ARN to associate. Use the waf-managed module to produce one.

    Ignored unless enable_waf = true. Setting this alone does nothing — that is
    deliberate, see enable_waf.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags merged on top of provider default_tags."
  type        = map(string)
  default     = {}
}
