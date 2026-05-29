resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = var.scope

  default_action {
    allow {}
  }

  ###########################################################################
  # AWS Common Rule Set - OWASP Top 10 coverage
  ###########################################################################
  rule {
    name     = "AWS-CommonRuleSet"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        dynamic "rule_action_override" {
          for_each = toset(var.common_rule_overrides_to_count)
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-CommonRuleSet"
    }
  }

  ###########################################################################
  # Known Bad Inputs
  ###########################################################################
  dynamic "rule" {
    for_each = var.enable_known_bad_inputs ? [1] : []
    content {
      name     = "AWS-KnownBadInputs"
      priority = 1

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesKnownBadInputsRuleSet"
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "AWS-KnownBadInputs"
      }
    }
  }

  ###########################################################################
  # IP Reputation
  ###########################################################################
  dynamic "rule" {
    for_each = var.enable_ip_reputation ? [1] : []
    content {
      name     = "AWS-IPReputation"
      priority = 2

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesAmazonIpReputationList"
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "AWS-IPReputation"
      }
    }
  }

  ###########################################################################
  # Anonymous IP (Tor / VPN / proxies) - off by default
  ###########################################################################
  dynamic "rule" {
    for_each = var.enable_anonymous_ip ? [1] : []
    content {
      name     = "AWS-AnonymousIP"
      priority = 3

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesAnonymousIpList"
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "AWS-AnonymousIP"
      }
    }
  }

  ###########################################################################
  # Rate limit
  ###########################################################################
  rule {
    name     = "RateLimit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
  }

  tags = merge(var.tags, { Name = var.name })
}

###############################################################################
# Optional logging
###############################################################################

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = length(var.logging_destination_arns) == 0 ? 0 : 1
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = var.logging_destination_arns

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
