###############################################################################
# WAF monitoring: SNS topics by severity, CloudWatch alarms per Web ACL,
# and a single dashboard with one row per Web ACL plus a rollup.
#
# Metric source: WAF emits metrics under the AWS/WAFV2 namespace with
# dimensions { WebACL, Region, Rule }. Rule = the rule's name set by the
# Web ACL (e.g. "AWS-CommonRuleSet", "RateLimit", "AllowList") or "ALL"
# for the per-WebACL aggregate.
#
# !! NAMESPACE CASING — DO NOT "CORRECT" THIS TO AWS/WAFv2 !!
#
# The namespace is "AWS/WAFV2" with a capital V. Per the AWS WAF developer
# guide (Viewing metrics and dimensions): "The AWS WAF namespace is
# AWS/WAFV2". CloudWatch namespaces are case-sensitive.
#
# This bit us. The original June 2026 delivery of this module used
# "AWS/WAFv2" (lowercase v). Because every alarm here also sets
# treat_missing_data = "notBreaching", all six alarms reported OK forever
# and every dashboard widget rendered empty — the monitoring looked healthy
# while watching a namespace that does not exist. Discovered 2026-08-06 when
# `list-metrics --namespace AWS/WAFv2` returned [] while the ALBs were
# demonstrably serving traffic.
#
# If you ever need to confirm the namespace is live:
#   aws cloudwatch list-metrics --namespace AWS/WAFV2 --region <region>
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
  namespace           = "AWS/WAFV2"
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
  namespace           = "AWS/WAFV2"
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
  namespace           = "AWS/WAFV2"
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
# Dead-man's switch: "is this Web ACL publishing metrics at all?"
#
# Every alarm above uses treat_missing_data = "notBreaching", which is correct
# for a *threshold* alarm (no blocks is good news) but means a
# silently-misconfigured alarm is indistinguishable from a healthy one. That is
# exactly how the AWS/WAFv2-vs-AWS/WAFV2 namespace typo survived seven weeks
# in production reporting all-OK.
#
# This alarm inverts the logic:
#   - metric  : AllowedRequests, which is non-zero whenever traffic flows
#   - operator: LessThanThreshold 1
#   - missing : "breaching"  <-- the whole point
#
# So it fires if the Web ACL stops seeing traffic OR if the metric cannot be
# resolved at all. Either way a human finds out instead of trusting a green
# dashboard that is watching nothing.
#
# !! WHY period = 3600 AND NOT 300 !!
#
# Per the AWS WAF developer guide (AWS WAF core metrics), EVERY WAF metric has
# "Reporting criteria: There is a nonzero value." WAF does not publish zeros —
# a quiet interval produces NO datapoint at all, which this alarm treats as
# breaching.
#
# At 5-minute granularity that makes the alarm unusable on low-traffic
# resources. Measured 2026-08-06: scriptcase-lb served 20 requests in 3 hours,
# roughly one every nine minutes, so most 5-minute windows are legitimately
# empty and the alarm would flap constantly.
#
# Aggregating to 1 hour fixes it: at ~7 requests/hour scriptcase still reports
# a nonzero AllowedRequests value every period, while a genuinely dead metric
# pipeline still produces nothing and still fires. Trade-off is detection
# latency (hours, not minutes) — acceptable, because this alarm exists to catch
# silent misconfiguration, not to page on live attacks. The threshold alarms
# above keep their 5-minute period for that.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "metric_liveness" {
  for_each = var.enable_liveness_alarm ? var.web_acls : {}

  alarm_name        = "${var.name}-${each.key}-no-metrics"
  alarm_description = <<-EOT
    ${each.value.name} has published no AllowedRequests datapoints for
    ${var.liveness_evaluation_periods} consecutive 1-hour periods.

    Either the resource genuinely stopped receiving traffic, or the WAF
    metric plumbing is broken (wrong namespace/dimensions, Web ACL detached
    from its load balancer, Web ACL deleted). Check in this order:
      1. aws cloudwatch list-metrics --namespace AWS/WAFV2 --region ${each.value.region}
      2. aws wafv2 get-web-acl-for-resource --resource-arn <alb-arn>
      3. ALB RequestCount in AWS/ApplicationELB (is traffic arriving at all?)
  EOT

  namespace   = "AWS/WAFV2"
  metric_name = "AllowedRequests"
  statistic   = "Sum"

  # 1 hour, NOT 300 — see the long note above. WAF publishes no datapoint for
  # a zero-traffic interval, so short periods make this flap on quiet sites.
  period              = 3600
  evaluation_periods  = var.liveness_evaluation_periods
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # The inversion that makes this a dead-man's switch. Do not change to
  # notBreaching — that would defeat the entire purpose of this alarm.
  treat_missing_data = "breaching"

  dimensions = {
    WebACL = each.value.name
    Region = each.value.region
    Rule   = "ALL"
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
            ["AWS/WAFV2", "AllowedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "ALL"],
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
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "AWS-CommonRuleSet"],
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
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.web_acls[key].name, "Region", var.web_acls[key].region, "Rule", "RateLimit"],
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
          "AWS/WAFV2", "BlockedRequests",
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
