###############################################################################
# ICC ALB (Perimeter). Public endpoint for the ICC CRM APIs on the
# insight-ubuntu-dev box in shared-prod.
#
# TLS is staged (see variables.tf / README):
#   1) First apply with enable_https=false -> HTTP-only ALB + ACM cert (PENDING).
#      Add the acm_validation_records CNAME(s) to insightgrouppr.com's external
#      DNS. Cert -> ISSUED.
#   2) Set enable_https=true, re-apply -> HTTPS listener attaches. Then point
#      both hostnames at the alb_dns_name output.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "icc-alb"
region       = "us-east-2"

# Same ingress VPC + public subnets as the shared ingress-alb / webapps-alb.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# The insight-ubuntu-dev box in shared-prod (over TGW). Both APIs live here.
backend_private_ip = "10.12.1.71"
prod_api_port      = 80
dev_api_port       = 81

prod_api_host = "crm.insightgrouppr.com"
dev_api_host  = "crm-dev.insightgrouppr.com"

health_check_path    = "/"
health_check_matcher = "200,301,302"

# Start HTTP-only so the ACM cert can validate against external DNS.
# Flip to true and re-apply once the cert is ISSUED.
enable_https = false
