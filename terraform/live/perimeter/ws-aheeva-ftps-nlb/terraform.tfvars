###############################################################################
# WS Aheeva FTPS NLB — Wave 2. Fill ws_aheeva_private_ip + client CIDRs.
# NARROW the passive range (with the Aheeva FTPS config) before apply — see README.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "ws-aheeva-ftps"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# From the sibling production/ws-aheeva leaf (pinned there).
ws_aheeva_private_ip = "10.12.1.66"

ftps_control_port = 990
# Narrowed passive range (20 ports) — MUST match the Aheeva FTPS server config.
# Source was 40000-40500 (501 ports) which exceeds the NLB listener quota.
ftps_passive_from = 40000
ftps_passive_to   = 40019

# FTPS client source IPs. Default open until confirmed — tighten before cutover.
# allowed_source_cidrs = ["<client1>/32", "<client2>/32"]
