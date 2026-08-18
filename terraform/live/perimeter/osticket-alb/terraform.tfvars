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

# Stage 2, enabled 2026-08-16. The ACM cert for osticket.insightgrouppr.com is
# ISSUED — the validation CNAME was published at Network Solutions and confirmed
# authoritative against ns47.worldnic.com, with no double-suffix artifact.
#
# Effect: an HTTPS:443 listener attaches with the cert, and HTTP:80 starts
# 301-redirecting to it. An ELB listener can only reference an ISSUED cert, so do
# not set this true before the cert has actually issued.
#
# This does NOT move user traffic. The public DNS record still points at the
# Lightsail box; this only makes the ALB serve HTTPS on its own address, which is
# what the pre-cutover verification test uses.
enable_https = true

# Bumped 1 -> 2 on 2026-08-13. The osticket.* request created on 2026-08-10 was
# never validated — the CNAME was never published at Network Solutions — so it
# hit ACM's 72-hour limit and moved to VALIDATION_TIMED_OUT, which is terminal.
# A timed-out cert shows no plan diff (status is computed), so re-applying would
# have changed nothing; bumping this serial is what forces a new request.
# See variables.tf for the mechanism, and main.tf for why it is done this way.
cert_request_serial = 2

###############################################################################
# Cert replacement history — read before chasing a validation CNAME.
#
# The hostname above was corrected from tickets.* to osticket.* in PR #57. That
# REPLACES the ACM certificate, so there have been two certs on this leaf:
#
#   1. arn:...:certificate/aaed79b9-5a02-4c35-bc23-276c4bc87b48
#      domain tickets.insightgrouppr.com. Never validated, never attached.
#      Destroyed by the replacement.
#   2. arn:...:certificate/8c2c365f-a408-4bbf-8f6e-187a28665057
#      domain osticket.insightgrouppr.com, created by the replacement and
#      applied 2026-08-10 (CI run 31396689872). Its validation CNAME
#      (_59bfd12229b222d5a7e78deac7838a08.osticket...) was never published, so
#      it hit ACM's 72-hour limit on 2026-08-13 and went VALIDATION_TIMED_OUT.
#      Terminal — a timed-out request cannot be validated later.
#   3. A new cert for osticket.insightgrouppr.com, forced by
#      cert_request_serial = 2 below. Record its ARN here once applied.
#
# CONSEQUENCE: every one of these has its OWN validation CNAME. If anyone
# already added an earlier cert's CNAME at Network Solutions, it is now useless
# and the current one has to be added instead. Always re-read the output rather
# than assuming a previously-added record still applies:
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
