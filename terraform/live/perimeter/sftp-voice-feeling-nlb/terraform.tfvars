###############################################################################
# SFTP VOFeeling NLB. Same VPC and public subnets as the existing sftp-nlb /
# wazuh-nlb leaves.
###############################################################################

account_name = "Perimeter"
account_id   = "713939170920"
stack_name   = "sftp-voice-feeling-nlb"
region       = "us-east-2"

ingress_vpc_id = "vpc-0f8cbc901a195b148"
public_subnet_ids = [
  "subnet-0e4b51e5c27c3ffbf",
  "subnet-079c23a68151cc828",
]

# Pinned in the production/sftp-voice-feeling leaf as 10.12.1.62.
sftp_server_private_ip = "10.12.1.62"

sftp_port = 22

# Partner source IPs carried over from the source F9_SFTP_SG (all TCP/22).
# The legacy 0-65535 rule from 67.219.151.138/32 (VICIDIAL AST1) is NOT
# reproduced — the NLB forwards only :22. Add extra ports explicitly if that
# host genuinely needs more than SFTP.
allowed_source_cidrs = [
  "67.219.151.134/32", # VICIDIAL AST 2
  "67.219.151.138/32", # VICIDIAL AST1
  "162.213.152.0/23",  # Five9 Server
  "198.105.207.0/24",  # Five9 Server
  "198.105.200.0/23",  # Five9 Server
  "208.69.28.0/23",    # Five9 Server
  "38.107.71.10/32",   # Five9 Server
  "181.204.67.42/32",  # PEI-BG
  "152.203.51.190/32", # CLARA VOFEELING
  "181.207.82.178/32", # ZIMA
]
