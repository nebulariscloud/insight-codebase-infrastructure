###############################################################################
# Bootstrap inputs. Copy to terraform.tfvars (gitignored) and edit there.
#
#   cp example.tfvars terraform.tfvars
#
# terraform.tfvars is what Terraform reads automatically.
###############################################################################

# Home region. Must match LZA HomeRegion.
region = "us-east-2"

# GitHub repos allowed to assume GitHubActions-Terraform via OIDC.
# Format: "owner/repo" — exact match, no wildcards.
# The OIDC trust pins to this string; changing it later requires re-running
# the bootstrap.
github_repos = [
  "nebulariscloud/insight-codebase-infrastructure",
]

# Defaults for everything else are fine:
#   - State bucket:  lza-terraform-state-<sharedservices-account-id>
#   - Lock table:    lza-terraform-locks
#   - KMS alias:     alias/lza-terraform-state
# These names are hardcoded in state-backend.tf. If you need different names,
# edit state-backend.tf before applying — they're inputs to every leaf
# backend config too.
