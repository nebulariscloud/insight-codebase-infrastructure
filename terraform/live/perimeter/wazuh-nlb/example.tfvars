###############################################################################
# Copy to terraform.tfvars and fill in the discovered values.
#
# Discovery commands (CloudShell, in the Perimeter account / us-east-2):
#
#   # ingress_vpc_id + public_subnet_ids - same ones the IngressALB uses
#   aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*ingress*" \
#     --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
#
#   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
#     "Name=tag:Name,Values=*public*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
#
#   # wazuh_manager_ips - private IPs of the manager(s) in shared-prod
#   aws ec2 describe-instances --filters "Name=tag:Name,Values=*wazuh*" \
#     --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,Tags[?Key==`Name`].Value|[0]]' \
#     --output table
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "wazuh-nlb"
region       = "us-east-2"

# From customizations-config.yaml (existing IngressALB params - verified there)
ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Default name in custom-stacks/ingress-alb.yaml
ingress_alb_name = "ingress-alb"

# REPLACE with the actual Wazuh manager private IP(s) from the discovery
# command above. Cluster -> add multiple entries.
wazuh_manager_ips = [
  "10.X.X.X",
]

# Optional - tighten to customer egress CIDRs once known. Default 0.0.0.0/0.
# ingress_cidrs = ["203.0.113.0/24"]
