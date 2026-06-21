###############################################################################
# Local action / priority bookkeeping.
#
# Priority order (lower = evaluated first):
#   0   AllowList     - vetted IPs short-circuit to Allow
#   1   DenyList      - known-bad IPs short-circuit to Block
#   2   GeoAllow/Block- geographic gate
#   3   AWS-CommonRuleSet
#   4   AWS-KnownBadInputs
#   5   AWS-IPReputation
#   6   AWS-AnonymousIP
#   7   AWS-BotControl
#  10   RateLimit
# 100+  Custom rules (caller-defined)
###############################################################################

locals {
  ip_v4_allow_enabled = length(var.allow_ip_cidrs) > 0
  ip_v4_deny_enabled  = length(var.deny_ip_cidrs) > 0
  ip_v6_allow_enabled = length(var.ip_set_ipv6_allow_cidrs) > 0
  ip_v6_deny_enabled  = length(var.ip_set_ipv6_deny_cidrs) > 0

  geo_allow_enabled = length(var.geo_allow_country_codes) > 0
  geo_block_enabled = length(var.geo_block_country_codes) > 0
}

###############################################################################
# IP sets - one per (family, action) combination, only created when used.
###############################################################################

resource "aws_wafv2_ip_set" "allow_v4" {
  count              = local.ip_v4_allow_enabled ? 1 : 0
  name               = "${var.name}-allow-v4"
  description        = "Vetted IPv4 sources for ${var.name}; short-circuits to Allow."
  scope              = var.scope
  ip_address_version = "IPV4"
  addresses          = var.allow_ip_cidrs
  tags               = merge(var.tags, { Name = "${var.name}-allow-v4" })
}

resource "aws_wafv2_ip_set" "deny_v4" {
  count              = local.ip_v4_deny_enabled ? 1 : 0
  name               = "${var.name}-deny-v4"
  description        = "Blocked IPv4 sources for ${var.name}; short-circuits to Block."
  scope              = var.scope
  ip_address_version = "IPV4"
  addresses          = var.deny_ip_cidrs
  tags               = merge(var.tags, { Name = "${var.name}-deny-v4" })
}

resource "aws_wafv2_ip_set" "allow_v6" {
  count              = local.ip_v6_allow_enabled ? 1 : 0
  name               = "${var.name}-allow-v6"
  description        = "Vetted IPv6 sources for ${var.name}; short-circuits to Allow."
  scope              = var.scope
  ip_address_version = "IPV6"
  addresses          = var.ip_set_ipv6_allow_cidrs
  tags               = merge(var.tags, { Name = "${var.name}-allow-v6" })
}

resource "aws_wafv2_ip_set" "deny_v6" {
  count              = local.ip_v6_deny_enabled ? 1 : 0
  name               = "${var.name}-deny-v6"
  description        = "Blocked IPv6 sources for ${var.name}; short-circuits to Block."
  scope              = var.scope
  ip_address_version = "IPV6"
  addresses          = var.ip_set_ipv6_deny_cidrs
  tags               = merge(var.tags, { Name = "${var.name}-deny-v6" })
}

###############################################################################
# Web ACL
###############################################################################

resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = var.scope

  default_action {
    allow {}
  }

  ###########################################################################
  # IP allow list - priority 0 (highest precedence after default deny order).
  # Combines IPv4 + IPv6 sets via an `or` statement when both are present.
  ###########################################################################
  dynamic "rule" {
    for_each = local.ip_v4_allow_enabled || local.ip_v6_allow_enabled ? [1] : []
    content {
      name     = "AllowList"
      priority = 0

      action {
        allow {}
      }

      statement {
        dynamic "or_statement" {
          for_each = local.ip_v4_allow_enabled && local.ip_v6_allow_enabled ? [1] : []
          content {
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.allow_v4[0].arn
              }
            }
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.allow_v6[0].arn
              }
            }
          }
        }

        dynamic "ip_set_reference_statement" {
          for_each = local.ip_v4_allow_enabled && !local.ip_v6_allow_enabled ? [1] : []
          content {
            arn = aws_wafv2_ip_set.allow_v4[0].arn
          }
        }

        dynamic "ip_set_reference_statement" {
          for_each = !local.ip_v4_allow_enabled && local.ip_v6_allow_enabled ? [1] : []
          content {
            arn = aws_wafv2_ip_set.allow_v6[0].arn
          }
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-AllowList"
      }
    }
  }

  ###########################################################################
  # IP deny list - priority 1.
  ###########################################################################
  dynamic "rule" {
    for_each = local.ip_v4_deny_enabled || local.ip_v6_deny_enabled ? [1] : []
    content {
      name     = "DenyList"
      priority = 1

      action {
        block {}
      }

      statement {
        dynamic "or_statement" {
          for_each = local.ip_v4_deny_enabled && local.ip_v6_deny_enabled ? [1] : []
          content {
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.deny_v4[0].arn
              }
            }
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.deny_v6[0].arn
              }
            }
          }
        }

        dynamic "ip_set_reference_statement" {
          for_each = local.ip_v4_deny_enabled && !local.ip_v6_deny_enabled ? [1] : []
          content {
            arn = aws_wafv2_ip_set.deny_v4[0].arn
          }
        }

        dynamic "ip_set_reference_statement" {
          for_each = !local.ip_v4_deny_enabled && local.ip_v6_deny_enabled ? [1] : []
          content {
            arn = aws_wafv2_ip_set.deny_v6[0].arn
          }
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-DenyList"
      }
    }
  }

  ###########################################################################
  # Geo allow - priority 2. Block any country that's NOT in the allow list
  # by negating a geo_match. (Mutually exclusive with geo_block below.)
  ###########################################################################
  dynamic "rule" {
    for_each = local.geo_allow_enabled ? [1] : []
    content {
      name     = "GeoAllow"
      priority = 2

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            geo_match_statement {
              country_codes = var.geo_allow_country_codes
            }
          }
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-GeoAllow"
      }
    }
  }

  ###########################################################################
  # Geo block - priority 2. Block specific countries; everywhere else is
  # allowed (subject to other rules below).
  ###########################################################################
  dynamic "rule" {
    for_each = local.geo_block_enabled ? [1] : []
    content {
      name     = "GeoBlock"
      priority = 2

      action {
        block {}
      }

      statement {
        geo_match_statement {
          country_codes = var.geo_block_country_codes
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-GeoBlock"
      }
    }
  }

  ###########################################################################
  # AWS Common Rule Set - OWASP Top 10 coverage
  ###########################################################################
  rule {
    name     = "AWS-CommonRuleSet"
    priority = 3

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
      priority = 4

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
      priority = 5

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
      priority = 6

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
  # Bot Control - opt-in (cost). COMMON or TARGETED inspection level.
  # AWSManagedRulesBotControlRuleSet's managed_rule_group_configs takes a
  # `aws_managed_rules_bot_control_rule_set` block to set the level.
  ###########################################################################
  dynamic "rule" {
    for_each = var.enable_bot_control ? [1] : []
    content {
      name     = "AWS-BotControl"
      priority = 7

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesBotControlRuleSet"

          managed_rule_group_configs {
            aws_managed_rules_bot_control_rule_set {
              inspection_level = var.bot_control_inspection_level
            }
          }

          dynamic "rule_action_override" {
            for_each = toset(var.bot_control_overrides_to_count)
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
        metric_name                = "AWS-BotControl"
      }
    }
  }

  ###########################################################################
  # Rate limit - priority 10
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

  ###########################################################################
  # Custom rules - caller-defined patterns. Two flavours supported here:
  #   - byte_match_statement: block/allow/count requests whose URI / header
  #     / query string matches a literal string.
  #   - rate_based_statement (with optional URI scope-down): per-IP rate
  #     limit on a specific path. Useful for protecting /login, /api, etc.
  ###########################################################################
  dynamic "rule" {
    for_each = { for r in var.custom_rules : r.name => r }
    content {
      name     = rule.value.name
      priority = rule.value.priority

      dynamic "action" {
        for_each = rule.value.action == "allow" ? [1] : []
        content {
          allow {}
        }
      }
      dynamic "action" {
        for_each = rule.value.action == "block" ? [1] : []
        content {
          block {}
        }
      }
      dynamic "action" {
        for_each = rule.value.action == "count" ? [1] : []
        content {
          count {}
        }
      }
      dynamic "action" {
        for_each = rule.value.action == "captcha" ? [1] : []
        content {
          captcha {}
        }
      }
      dynamic "action" {
        for_each = rule.value.action == "challenge" ? [1] : []
        content {
          challenge {}
        }
      }

      statement {
        dynamic "byte_match_statement" {
          for_each = rule.value.byte_match_statement == null ? [] : [rule.value.byte_match_statement]
          content {
            search_string         = byte_match_statement.value.search_string
            positional_constraint = byte_match_statement.value.positional_constraint

            field_to_match {
              dynamic "uri_path" {
                for_each = byte_match_statement.value.field == "uri_path" ? [1] : []
                content {}
              }
              dynamic "query_string" {
                for_each = byte_match_statement.value.field == "query_string" ? [1] : []
                content {}
              }
              dynamic "method" {
                for_each = byte_match_statement.value.field == "method" ? [1] : []
                content {}
              }
              dynamic "single_header" {
                for_each = byte_match_statement.value.field == "single_header_user_agent" ? [1] : []
                content {
                  name = "user-agent"
                }
              }
              dynamic "single_header" {
                for_each = byte_match_statement.value.field == "single_header_referer" ? [1] : []
                content {
                  name = "referer"
                }
              }
            }

            dynamic "text_transformation" {
              for_each = { for i, t in coalesce(byte_match_statement.value.text_transformations, ["NONE"]) : i => t }
              content {
                priority = text_transformation.key
                type     = text_transformation.value
              }
            }
          }
        }

        dynamic "rate_based_statement" {
          for_each = rule.value.rate_based_statement == null ? [] : [rule.value.rate_based_statement]
          content {
            limit              = rate_based_statement.value.limit
            aggregate_key_type = rate_based_statement.value.aggregate_key_type

            dynamic "scope_down_statement" {
              for_each = lookup(rate_based_statement.value, "scope_down_uri_starts_with", "") == "" ? [] : [1]
              content {
                byte_match_statement {
                  search_string         = rate_based_statement.value.scope_down_uri_starts_with
                  positional_constraint = "STARTS_WITH"

                  field_to_match {
                    uri_path {}
                  }

                  text_transformation {
                    priority = 0
                    type     = "NONE"
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        sampled_requests_enabled   = true
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric_name == "" ? rule.value.name : rule.value.metric_name
      }
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

  dynamic "redacted_fields" {
    for_each = toset(var.logging_redacted_headers)
    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }
}
