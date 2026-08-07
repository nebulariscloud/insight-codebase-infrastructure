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

# TODO: confirm the real hostname with the app owner before the first apply —
# it is baked into the ACM cert, so changing it later means a new cert.
# The Lightsail box was reached on static IP 204.236.253.33; there may already
# be a hostname pointing there today that should simply be reused.
osticket_host = "tickets.insightgrouppr.com"

# osTicket's "/" usually 302s, so redirects count as healthy.
health_check_path    = "/"
health_check_matcher = "200,301,302"

# Stage 1: HTTP-only until the ACM cert validates. Flip to true afterwards.
enable_https = false
