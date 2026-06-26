###############################################################################
# Moodle (Production / shared-prod, us-east-2).
#
# AMI build trail (for the runbook):
#   Source Lightsail snapshot (us-east-1):     snap-02a8e6434c2423dc2
#   Re-encrypted under shareable CMK (src):    snap-0995aaac879dc9155
#   Cross-region copy under LZA EBS key (dst): snap-0a5eb336adef94c60
#   Registered AMI in us-east-2:               ami-0650031d536e756ab
#
# Cutover sequence after `terraform apply`:
#   1. aws ssm start-session --region us-east-2 --target <instance-id>
#   2. sudo nano /opt/bitnami/apache/htdocs/config.php
#        $CFG->wwwroot  = 'https://moodle.<corp>.com';
#        $CFG->sslproxy = true;
#   3. sudo /opt/bitnami/ctlscript.sh restart apache
#   4. Add target group + host-header rule on the perimeter ingress ALB
#      pointing at the private_ip output of this stack.
#   5. Flip DNS to the ALB.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "moodle"
region       = "us-east-2"

name          = "moodle"
instance_type = "t3a.small"
ami_id        = "ami-0650031d536e756ab"

# Same VPC + AZ as the other migrated workloads in this subnet.
#   vpc-04a8720d0ddb40713    = AWSAccelerator-us-east-2-shared-prod
#   subnet-00d31cac6422417c4 = AWSAccelerator-us-east-2-shared-prod-app-a (10.12.1.0/24)
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Existing tenants in 10.12.1.0/24:
#   10.12.1.50  - sftp-server
#   10.12.1.121 - wazuh
#   10.12.1.174 - scriptcase-php-73
# .60 is the next clean slot above sftp.
private_ip = "10.12.1.60"

root_volume_size_gib = 60
moodle_http_port     = 80
ingress_vpc_cidr     = "10.0.0.0/20"

# EICE endpoint SG in shared-prod (reused from sftp-server). Lets us SSH
# in as a fallback if SSM ever has issues. Leave empty to disable.
eice_security_group_id = "sg-0a990a87e6abca926"
