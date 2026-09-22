variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Perimeter spoke."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "stack_name" {
  description = "Short stack name."
  type        = string
  default     = "webapps-alb"
}

variable "region" {
  description = "AWS region the ALB lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. Same VPC the shared ingress-alb / crm-alb live in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in the perimeter ingress VPC, one per AZ (>= 2)."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires at least two subnets in different AZs."
  }
}

variable "allowed_source_cidrs" {
  description = "Source CIDRs allowed inbound to the ALB on 80/443. Default internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------------
# Backends — the two migrated webapp boxes in shared-prod (over TGW).
#
# Reproduces the source WebappsALB routing:
#   named app paths (the "abbvie" set) -> webapps-php73 (i-02a7982851dd09a0b)
#   everything else (catch-all)        -> webapps      (i-0fb5b86437a72deb5)
# Both serve plain HTTP on :80; TLS terminates at this ALB.
# ----------------------------------------------------------------------------

variable "webapps_private_ip" {
  description = <<-EOT
    Private IP of the webapps (catch-all) box in shared-prod. Read from:
      cd ../../production/webapps && terraform output -raw private_ip
    (Currently 10.12.1.65.)
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.webapps_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "webapps_php73_private_ip" {
  description = <<-EOT
    Private IP of the webapps-php73 (named app paths) box in shared-prod. Read from:
      cd ../../production/webapps-php73 && terraform output -raw private_ip
    (Currently 10.12.1.61.)
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.webapps_php73_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "backend_port" {
  description = "Backend HTTP port both webapp boxes listen on."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "HTTP health check path on the backends. Matches the source TGs (/healthy.txt)."
  type        = string
  default     = "/healthy.txt"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy. Source TGs used 200."
  type        = string
  default     = "200"
}

# ----------------------------------------------------------------------------
# URI routing — the "abbvie" path set that goes to webapps-php73.
#
# Copied verbatim from the source WebappsALB 443 listener rules (priorities
# 1-8). ALB allows a maximum of 5 path-pattern values per rule condition, so
# these are grouped into chunks of <= 5; one aws_lb_listener_rule is created
# per group. Everything NOT matching falls through to the listener default
# action, which forwards to the webapps (catch-all) box — same as the source
# priority-9 "*" rule.
#
# Path matching on ALB is case-sensitive and supports * / ? wildcards, so the
# mixed-case and glob-middle patterns (/AAA-BI/*, /ssspq*/*, /sss_agencias_*/*)
# are carried through unchanged.
# ----------------------------------------------------------------------------

variable "php73_path_groups" {
  description = <<-EOT
    Groups of URI path patterns routed to the webapps-php73 box. Each group
    becomes one ALB listener rule. Order determines rule priority. Reproduces
    the source WebappsALB abbvieTG rules verbatim.

    Two ALB limits apply PER RULE and both are respected here:
      - at most 5 path-pattern values, AND
      - at most 6 wildcard characters (*/?) across all values in the rule.

    The second limit is the one that bit us on 2026-09-22: a group of 5 values
    that included both /ssspq*/* and /sss_agencias_*/* (2 wildcards each) came
    to 7 wildcards and CreateRule failed with "A rule can only have '6'
    condition wildcards". The two double-wildcard patterns are now split into a
    group whose total stays <= 6.
  EOT
  type        = list(list(string))
  default = [
    # 5 wildcards
    ["/island/*", "/webhook/*", "/abbvie_aheeva/*", "/ah_amex/*", "/AAA-BI/*"],
    # 5 wildcards
    ["/AAA_Survey/*", "/sss_holiday/*", "/aaa_aheeva_survey_reports/*", "/electric/*", "/testing/*"],
    # 5 wildcards
    ["/testing_admin/*", "/testing2/*", "/clarocrm/*", "/aaa_referidos/*", "/ehret/*"],
    # 5 wildcards: /aeronet/* (1) + /ssspq*/* (2) + /sss_agencias_*/* (2)
    ["/aeronet/*", "/ssspq*/*", "/sss_agencias_*/*"],
  ]

  validation {
    condition = alltrue([
      for g in var.php73_path_groups : length(g) <= 5
    ])
    error_message = "Each path group maps to one ALB rule, which allows at most 5 path-pattern values."
  }

  validation {
    # length(join(...)) counts wildcard chars without sum(), which errors on an
    # empty list. join yields "" for an empty group, length 0.
    condition = alltrue([
      for g in var.php73_path_groups :
      length(regexall("[*?]", join("", g))) <= 6
    ])
    error_message = "Each path group maps to one ALB rule, which allows at most 6 wildcard characters (*/?) across its values."
  }
}

# ----------------------------------------------------------------------------
# TLS / cert
#
# ACM cert for webapps.insightgrouppr.com, DNS validation. insightgrouppr.com
# DNS is managed OUTSIDE Route53, so the validation records are emitted as
# outputs for the DNS admin to add by hand (same as crm-alb).
#
# HTTPS is staged:
#   1) First apply enable_https=false -> HTTP-only ALB + cert (PENDING).
#      Add the acm_validation_records CNAME to external DNS. Cert -> ISSUED.
#   2) Set enable_https=true and re-apply -> HTTPS listener attaches with the
#      path rules, HTTP 301-redirects to HTTPS. Then point
#      webapps.insightgrouppr.com at alb_dns_name.
# ----------------------------------------------------------------------------

variable "app_host" {
  description = "Hostname the ALB serves and the ACM cert covers. Matches the source cert."
  type        = string
  default     = "webapps.insightgrouppr.com"
}

variable "enable_https" {
  description = <<-EOT
    Flip to true only AFTER the ACM cert is ISSUED (validation record added to
    external DNS). Attaches the HTTPS listener + path rules and redirects
    HTTP->HTTPS. Keep false on the first apply so the cert can validate.
  EOT
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# WAF
# ----------------------------------------------------------------------------

variable "waf_rate_limit" {
  description = "Requests per 5 minutes per source IP before the rate-based rule blocks. Matches the other public ALBs."
  type        = number
  default     = 2000
}
