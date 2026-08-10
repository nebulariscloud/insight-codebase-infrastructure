account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "waf-logs"
region       = "us-east-2"

# Every REGIONAL Web ACL in Perimeter. All four public ALBs are fronted by
# one of these, so this list is also the answer to "is every protected
# resource logging?".
#
#   ingress-alb-waf    -> ingress-alb    (Wazuh)      CFN / LZA custom-stack
#   scriptcase-lb-waf  -> scriptcase-lb               CFN / LZA custom-stack
#   crm-alb-waf        -> crm-alb                     Terraform live leaf
#   osticket-alb-waf   -> osticket-alb                Terraform live leaf
#
# When a new ALB gets a Web ACL, add it here in the same PR. Verify with
# waf-finish-checklist.md step 6.
web_acl_names = [
  "ingress-alb-waf",
  "scriptcase-lb-waf",
  "crm-alb-waf",
  "osticket-alb-waf",
]

# 365 days mirrors LZA's central log bucket retention. Drop to 90 if cost is
# tight; raise to 730 if compliance asks for two years.
log_retention_days = 365
