account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "waf-monitoring"
region       = "us-east-2"

###############################################################################
# Web ACLs + per-ACL alarm thresholds.
#
# Keys feed alarm names (perimeter-waf-<key>-<alarm-type>) and are therefore
# STABLE IDENTIFIERS. Do not rename an existing key — that destroys its alarms
# and their history.
#
# All thresholds are Sum of BlockedRequests per 5-minute window, and fire after
# `evaluation_periods` (default 2) consecutive breaching periods.
#
# Values derived from a 4-day measurement in Perimeter on 2026-08-08; the raw
# numbers and reasoning live in docs/waf/waf-traffic-baseline.md. Summary of the
# observed peaks per 5-minute window:
#
#                     ingress-alb-waf   scriptcase-lb-waf
#   BlockedRequests            2464               297
#     AWS-IPReputation         1712               182
#     AWS-CommonRuleSet         419               231
#     AWS-KnownBadInputs        387               107
#   AllowedRequests             763               972
#   RateLimit                     0                 0     (never fired)
#
# Two things drive the numbers below:
#
# 1. IP-reputation dominance. On ingress, ~65% of all blocks are
#    AWS-IPReputation catching botnet/scanner traffic. That is WAF working, not
#    an incident. So blocked_requests_threshold is set ABOVE the observed peak
#    (4000 vs 2464) to mean "volume well beyond routine sweeps", rather than
#    paging on every scan.
#
# 2. The actionable signals are CommonRuleSet and KnownBadInputs, which mean
#    somebody is probing the application itself. Those are set at roughly
#    1.5-2x observed peak so a genuine escalation trips them.
###############################################################################

web_acls = {
  # Wazuh dashboard/API. Busiest, and the most scanner-attractive.
  ingress = {
    name                             = "ingress-alb-waf"
    blocked_requests_threshold       = 4000 # peak 2464, mostly IP-reputation noise
    common_rule_set_block_threshold  = 700  # peak 419
    known_bad_inputs_block_threshold = 600  # peak 387
    rate_limit_block_threshold       = 100  # never fired in 4 days
  }

  # Scriptcase. Lower volume, but proportionally MORE app-layer probing —
  # CommonRuleSet (231) outranks IPReputation (182) here, unlike on ingress.
  scriptcase = {
    name                             = "scriptcase-lb-waf"
    blocked_requests_threshold       = 600 # peak 297
    common_rule_set_block_threshold  = 400 # peak 231
    known_bad_inputs_block_threshold = 250 # peak 107
    rate_limit_block_threshold       = 100 # never fired in 4 days
  }

  # The two Web ACLs created by PR #60. No baseline yet, so these inherit the
  # module defaults (600 / 100 / 400 / 300) deliberately — revisit once they
  # have a week of data.
  #
  # Safe to list before the Web ACLs exist: this leaf does no ARN lookup, so
  # their alarms just sit in INSUFFICIENT_DATA until metrics flow. The
  # -no-metrics liveness alarms WILL fire for them in the meantime, which is
  # the correct signal that they are not yet reporting.
  crm = {
    name = "crm-alb-waf"
  }

  osticket = {
    name = "osticket-alb-waf"
  }
}

# These default in variables.tf to the SecurityHigh/Medium/Low addresses
# from replacements-config.yaml. Override here only if the security DLs change.
# sns_email_high   = "insightgroup-security-high@nebulariscloud.com"
# sns_email_medium = "insightgroup-security-medium@nebulariscloud.com"
# sns_email_low    = "insightgroup-security-low@nebulariscloud.com"
