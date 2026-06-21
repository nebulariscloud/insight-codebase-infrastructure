###############################################################################
# WAF monitoring: SNS topics by severity, CloudWatch alarms per Web ACL,
# and a single dashboard with one row per Web ACL plus a rollup.
#
# Metric source: WAF emits metrics under the AWS/WAFv2 namespace with
# dimensions { WebACL, Region, Rule }. Rule = the rule's name set by the
# Web ACL (e.g. "AWS-CommonRuleSet", "RateLimit", "AllowList") or "ALL"
# for the per-WebACL aggregate.
###############################################################################

locals {
  default_tags = merge(
    {
      ManagedBy = "Terraform"
      Module    = "waf-monitoring"
      Stack     = var.name
    },
    var.tags,
  )

  # Dashboard widget grid. One row per Web ACL.
  webacl_keys = sort(keys(var.web_acls))
}

###############################################################################
# SNS topics by severity
###############################################################################

resource "aws_sns_topic" "high" {
  name = "${var.name}-high"
  tags = local.default_tags
}

resource "aws_sns_topic" "medium" {
  name = "${var.name}-medium"
  tags = local.default_tags
}

resource "aws_sns_topic" "low" {
  count = var.sns_email_low == "" ? 0 : 1
  name  = "${var.name}-low"
  tags  = local.default_tags
}

resource "aws_sns_topic_subscription" "high_email" {
  topic_arn = aws_sns_topic.high.arn
  protocol  = "email"
  endpoint  = var.sns_email_high
}

resource "aws_sns_topic_subscription" "medium_email" {
  topic_arn = aws_sns_topic.medium.arn
  protocol  = "email"
  endpoint  = var.sns_email_medium
}

resource "aws_sns_topic_subscription" "low_email" {
  count     = var.sns_email_low == "" ? 0 : 1
  topic_arn = aws_sns_topic.low[0].arn
  protocol  = "email"
  endpoint  = var.sns_email_low
}

###############################################################################
# Alarms - per Web ACL
###############################################################################

# Total blocked requests per Web ACL (rule = ALL is the per-WebACL aggregate)
resource "aws_cloudwatch_metric_alarm" "blocked_total" {
  for_each = var.web_acls

  alarm_name          = "${var.name}-${each.key}-blocked-total"
  alarm_description   = "WAF total BlockedRequests on ${each.value.name} above threshold."
  namespace           = "AWS/WAFv2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = var.evaluation_periods
  threshold           = var.blocked_requests_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = each.value.name
    Region = each.value.region
    Rule   = "ALL"
  }

  alarm_actions = [aws_sns_topic.medium.arn]
  ok_actions    = [aws_sns_topic.medium.arn]
  tags          = local.default_tags
}

# RateLimit triggers - high severity (sustained DDoS / abuse signal)
resource "aws_cloudwatch_metric_alarm" "rate_limit_blocks" {
  for_each = var.web_acls

  alarm_name          = "${var.name}-${each.key}-rate-limit-blocks"
  alarm_description   = "WAF RateLimit rule blocked requests on ${each.value.name} - likely sustained abuse."
  namespace           = "AWS/WAFv2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = var.evaluation_periods
  threshold           = var.rate_limit_block_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = each.value.name
    Region = each.value.region
    Rule   = "RateLimit"
  }

  alarm_actions = [aws_sns_topic.high.arn]
  ok_actions    = [aws_sns_topic.high.arn]
  tags          = local.default_tags
}

# CommonRuleSet block spikes - medium (new attack pattern or bad deploy)
resource "aws_cloudwatch_metric_alarm" "common_rule_blocks" {
  for_each = var.web_acls

  alarm_name          = "${var.name}-${each.key}-common-ruleset-blocks"
  alarm_description   = "WAF AWS-CommonRuleSet block count on ${each.value.name} above baseline."
  namespace           = "AWS/WAFv2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = var.evaluation_periods
  threshold           = var.common_rule_set_block_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = each.value.name
    Region = each.value.region
    Rule   = "AWS-CommonRuleSet"
  }

  alarm_actions = [aws_sns_topic.medium.arn]
  ok_actions    = [aws_sns_topic.medium.arn]
  tags          = local.default_tags
}

###############################################################################
# Dashboard - one row of widgets per Web ACL, plus a rollup row.
###############################################################################

locals {
  # Widget builder: per-WebACL row at y = i*6 with three widgets:
  #   col 0-7  : allowed vs blocked requests (line, stacked)
  #   col 8-15 : blocks broken down by rule (line)
  #   col 16-23: rate-limit specifically (number)
  per_webacl_widgets = flatten([
    for i, key in local.webacl_keys : [
      {
        type   = "metric"
        x      = 0
        y      = i * 6
        width  = 8
        height = 6
        properties = {
          title   = "${var.web_acls[key].name} - traffic"
          region  = var.web_acls[key].region
          stat    = "Sum"
          period  = 300
          view    = "timeSeries"
          stacked = true
          metrics = [
            ["AWS/WAFv2", "AllowedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "ALL"],
            [".", "BlockedRequests", ".", ".", ".", ".", ".", "."],
            [".", "CountedRequests", ".", ".", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = i * 6
        width  = 8
        height = 6
        properties = {
          title  = "${var.web_acls[key].name} - blocks by rule"
          region = var.web_acls[key].region
          stat   = "Sum"
          period = 300
          view   = "timeSeries"
          metrics = [
            ["AWS/WAFv2", "BlockedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "AWS-CommonRuleSet"],
            ["...", "AWS-KnownBadInputs"],
            ["...", "AWS-IPReputation"],
            ["...", "AWS-AnonymousIP"],
            ["...", "AWS-BotControl"],
            ["...", "RateLimit"],
            ["...", "AllowList"],
            ["...", "DenyList"],
            ["...", "GeoAllow"],
            ["...", "GeoBlock"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = i * 6
        width  = 8
        height = 6
        properties = {
          title  = "${var.web_acls[key].name} - rate limit"
          region = var.web_acls[key].region
          stat   = "Sum"
          period = 300
          view   = "singleValue"
          metrics = [
            ["AWS/WAFv2", "BlockedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "RateLimit"],
          ]
        }
      },
    ]
  ])

  rollup_y = length(local.webacl_keys) * 6

  rollup_widget = {
    type   = "metric"
    x      = 0
    y      = local.rollup_y
    width  = 24
    height = 6
    properties = {
      title  = "Total blocked requests across all Web ACLs"
      region = length(local.webacl_keys) > 0 ? var.web_acls[local.webacl_keys[0]].region : "us-east-2"
      stat   = "Sum"
      period = 300
      view   = "timeSeries"
      metrics = [
        for key in local.webacl_keys : [
          "AWS/WAFv2", "BlockedRequests",
          "WebACL", var.web_acls[key].name,
          "Region", var.web_acls[key].region,
          "Rule", "ALL",
          { label = var.web_acls[key].name },
        ]
      ]
    }
  }

  dashboard_body = jsonencode({
    widgets = concat(local.per_webacl_widgets, [local.rollup_widget])
  })
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = var.name
  dashboard_body = local.dashboard_body
}
