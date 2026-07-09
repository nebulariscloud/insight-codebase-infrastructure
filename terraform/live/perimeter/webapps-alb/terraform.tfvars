###############################################################################
# Dedicated webapps ALB (Perimeter). Fill cert ARN, hostnames, and the two
# backend private IPs (from the production/webapps* leaf outputs) before apply.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "webapps-alb"
region       = "us-east-2"

# Same ingress VPC + public subnets as the shared ingress-alb / sftp-nlb.
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# No ACM cert yet — HTTP-only interim. The ALB serves plain HTTP and the
# host-header rules attach to the HTTP listener. TODO: request an ACM cert in
# us-east-2 (Perimeter) covering both hostnames, set it here, re-apply → HTTP
# auto-redirects to HTTPS and rules move to the HTTPS listener.
certificate_arn = ""

# Backend private IPs — pinned in the production/webapps* leaves.
webapps_server_private_ip = "10.12.1.65"
webapps_php73_private_ip  = "10.12.1.61"

# Host headers that route to each app. TODO: set to the real DNS names before
# the ALB is useful; placeholders below just make the rules valid.
webapps_server_host = "webapps.example.com"
webapps_php73_host  = "php73.example.com"

target_port          = 80
health_check_path    = "/"
health_check_matcher = "200,301,302"
