###############################################################################
# Webapps ALB (Perimeter). Reproduces the source WebappsALB URI routing:
#   named app paths -> webapps-php73 (10.12.1.61)
#   everything else -> webapps       (10.12.1.65)
#
# TLS is staged (see variables.tf / README):
#   1) First apply with enable_https=false -> HTTP-only ALB + ACM cert (PENDING).
#      Add the acm_validation_records CNAME to webapps.insightgrouppr.com's
#      external DNS. Cert -> ISSUED.
#   2) Set enable_https=true, re-apply -> HTTPS listener + path rules attach,
#      HTTP 301-redirects to HTTPS. Then point the hostname at alb_dns_name.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "webapps-alb"
region       = "us-east-2"

# Same ingress VPC + public subnets as the shared ingress-alb / crm-alb.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Migrated backends in shared-prod (over TGW).
webapps_private_ip       = "10.12.1.65" # catch-all
webapps_php73_private_ip = "10.12.1.61" # named app paths

backend_port = 80

# Source TGs used /healthy.txt -> 200 on both boxes.
health_check_path    = "/healthy.txt"
health_check_matcher = "200"

# Keep false on the first apply so the ACM cert can DNS-validate against the
# external DNS. Flip to true and re-apply once the cert is ISSUED.
enable_https = false
