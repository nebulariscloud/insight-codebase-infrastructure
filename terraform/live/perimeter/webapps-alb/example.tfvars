###############################################################################
# Copy to terraform.tfvars and fill in.
#
# Backend IPs come from the sibling production leaves after they apply:
#   cd ../../production/webapps       && terraform output -raw private_ip
#   cd ../../production/webapps-php73 && terraform output -raw private_ip
#
# Cert: an ACM cert in us-east-2 (Perimeter account) covering both hostnames.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "webapps-alb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

certificate_arn = "arn:aws:acm:us-east-2:713939170920:certificate/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"

webapps_server_private_ip = "10.12.1.60"
webapps_php73_private_ip  = "10.12.1.61"

webapps_server_host = "webapps.example.com"
webapps_php73_host  = "php73.example.com"

target_port          = 80
health_check_path    = "/"
health_check_matcher = "200,301,302"

# allowed_source_cidrs = ["0.0.0.0/0"]
# waf_web_acl_arn      = "arn:aws:wafv2:us-east-2:713939170920:regional/webacl/..."
