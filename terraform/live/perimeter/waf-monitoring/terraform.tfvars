account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "waf-monitoring"
region       = "us-east-2"

ingress_web_acl_name    = "ingress-alb-waf"
scriptcase_web_acl_name = "scriptcase-lb-waf"

# These default in variables.tf to the SecurityHigh/Medium/Low addresses
# from replacements-config.yaml. Override here only if the security DLs
# change.
# sns_email_high   = "insightgroup-security-high@nebulariscloud.com"
# sns_email_medium = "insightgroup-security-medium@nebulariscloud.com"
# sns_email_low    = "insightgroup-security-low@nebulariscloud.com"
