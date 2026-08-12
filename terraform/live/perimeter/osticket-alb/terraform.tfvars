###############################################################################
# osTicket ALB (Perimeter). Public endpoint for the osTicket instance migrated
# off Lightsail into shared-prod.
#
# TLS is staged (see variables.tf / README):
#   1) First apply with enable_https = false -> HTTP-only ALB + ACM cert PENDING.
#      Add the CNAME from the acm_validation_records output to DNS. Cert -> ISSUED.
#   2) Set enable_https = true, re-apply -> HTTPS listener attaches, HTTP
#      301-redirects. Then point the hostname at the alb_dns_name output.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "osticket-alb"
region       = "us-east-2"

# Same ingress VPC + public subnets as crm-alb and the shared ingress-alb.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# The osTicket box in shared-prod (over TGW), pinned by
# terraform/live/production/osticket.
backend_private_ip = "10.12.1.67"
osticket_port      = 80

# The hostname in use today. `dig osticket.insightgrouppr.com` returns an A
# record, so this is the name to reuse rather than inventing a new one.
# Lowercase deliberately: ACM normalises the domain name, and a mixed-case value
# here makes the domain_validation_options key not match, which shows up as a
# perpetual diff on the acm_validation_records output.
#
# NOTE: that A record currently resolves to 54.84.28.176, NOT the Lightsail
# static IP 204.236.253.33 recorded in the production leaf. Confirm which box is
# actually serving before the DNS cutover in step 5 of the README.
osticket_host = "osticket.insightgrouppr.com"

# osTicket's "/" usually 302s, so redirects count as healthy.
health_check_path    = "/"
health_check_matcher = "200,301,302"

# Stage 1: HTTP-only until the ACM cert validates. Flip to true afterwards.
enable_https = false

###############################################################################
# Cert replacement history — read before chasing a validation CNAME.
#
# The hostname above was corrected from tickets.* to osticket.* in PR #57. That
# REPLACES the ACM certificate, so there have been two certs on this leaf:
#
#   1. arn:...:certificate/aaed79b9-5a02-4c35-bc23-276c4bc87b48
#      domain tickets.insightgrouppr.com. Never validated, never attached.
#      Destroyed by the replacement.
#   2. A new cert for osticket.insightgrouppr.com, created by the replacement.
#
# CONSEQUENCE: the new cert has its OWN validation CNAME. If anyone already
# added the first cert's CNAME at Network Solutions, it is now useless and the
# new one has to be added instead. Always re-read the output rather than
# assuming a previously-added record still applies:
#
#   terraform output acm_validation_records
#
# Timeline note: #57 merged 2026-08-08 but its apply was BLOCKED by the destroy
# guard (#61), because that first version of the guard read only the commit
# message and the authorisation had been written in the PR description. Fixed in
# #63; this leaf's apply is being re-driven now to actually perform the
# replacement. Nothing was broken by the delay — the old cert was unvalidated
# and unattached the whole time.
###############################################################################
