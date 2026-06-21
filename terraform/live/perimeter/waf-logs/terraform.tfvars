account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "waf-logs"
region       = "us-east-2"

# Match the existing CFN-managed Web ACL names. Override only if you've
# renamed them in custom-stacks/.
ingress_web_acl_name    = "ingress-alb-waf"
scriptcase_web_acl_name = "scriptcase-lb-waf"

# 365 days mirrors LZA's central log bucket retention. Drop to 90 if cost is
# tight; raise to 730 if compliance asks for two years.
log_retention_days = 365
