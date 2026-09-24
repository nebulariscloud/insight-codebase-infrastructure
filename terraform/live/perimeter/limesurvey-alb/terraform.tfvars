###############################################################################
# LimeSurvey ALB (Perimeter). Endpoint for the icc-limesurvey box in shared-prod.
#
# INTERIM: HTTP-only (enable_https=false, no cert). LimeSurvey is reachable at
# the ALB's own AWS DNS name (alb_dns_name output) — no domain needed yet. When
# the domain is ready, add an ACM cert + flip enable_https (mirror osticket-alb).
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "limesurvey-alb"
region       = "us-east-2"

# Same ingress VPC + public subnets as osticket-alb / crm-alb.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# The icc-limesurvey box in shared-prod (over TGW), pinned by
# terraform/live/production/icc-limesurvey.
backend_private_ip = "10.12.1.83"
backend_port       = 80

# LimeSurvey's / usually 200s or 302s.
health_check_path    = "/"
health_check_matcher = "200,301,302"

# Interim HTTP-only. Flip to true (and add a cert) once the domain is ready.
enable_https = false

# allowed_source_cidrs defaults to the partner allowlist in variables.tf
# (carried from the source webserver SG's :443 rule). Override here to change it.
