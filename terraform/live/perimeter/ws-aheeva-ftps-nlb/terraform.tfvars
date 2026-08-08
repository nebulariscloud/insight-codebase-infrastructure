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

# FTPS clients, read from the source SG sg-0236c297e78a62ab2 on 2026-08-07.
# The same eight /32s appear on both the control port (990) and the passive range
# (40000-40500) in the source, which is a good sign the list is accurate and
# maintained rather than accumulated.
allowed_source_cidrs = [
  "64.89.2.20/32",      # Insight WNet (Kennedy)      - also reachable over the Kennedy VPN
  "64.89.2.21/32",      # QNAP217 (Insight NAS)       - also reachable over the Kennedy VPN
  "154.64.223.34/32",   # Insight FiberX (Kennedy)    - also reachable over the Kennedy VPN
  "24.139.143.242/32",  # Insight Liberty             - also reachable over the Liberty VPN
  "162.246.173.122/32", # HCS                         - genuinely external
  "20.75.27.51/32",     # Accepta PY processor        - genuinely external
  "104.209.183.94/32",  # Accepta PY processor        - genuinely external
  "97.102.155.98/32",   # Gonzalo (individual)        - see note below
]

# Two follow-ups, deliberately NOT done before cutover:
#
# 1. Four of these eight are Insight's own sites that now terminate IPsec into
#    shared-prod (Kennedy x3, Liberty x1). They could drop files privately over the
#    TGW straight to 10.12.1.66 and skip this public NLB entirely, which would halve
#    the public exposure. Not done now on purpose: it means those sites change both
#    their target address AND their routing in the same window as everything else.
#    Cleaner as a follow-up once the NLB path is proven. Note their source address
#    over the tunnel is their INTERNAL range, not the public /32 above.
#
# 2. `97.102.155.98/32` is labelled with a person's name, which usually means a
#    workstation doing manual drops on a dynamic residential or office address.
#    Worth confirming it is still needed and whether it should be a named FTPS
#    account over the VPN instead of a public /32 that silently breaks on renewal.
