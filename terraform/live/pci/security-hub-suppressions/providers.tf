###############################################################################
# Provider chain for the PCI account security-hub-suppressions leaf.
#
# Step 1: aws.tooling stays in SharedServices (where GitHub Actions OIDC role
#         lands). Used to resolve the PCI account ID from SSM.
# Step 2: Default provider re-assumes TerraformExecution into the PCI account.
#
# Security Hub automation rules are global (not region-scoped) when region
# aggregation is enabled in security-config.yaml, so a single us-east-2
# provider is sufficient.
#
# Scope note: automation rules created in a member account (PCI) apply only
# to findings in that account. This is correct because all CloudFormation.4
# findings in scope are PCI-account findings (confirmed 2026-09-07).
###############################################################################

provider "aws" {
  alias  = "tooling"
  region = "us-east-2"
}

# Optional SSM lookup: only runs when var.account_id is empty.
data "aws_ssm_parameter" "spoke_account_id" {
  count    = var.account_id == "" ? 1 : 0
  provider = aws.tooling
  name     = var.account_id_ssm_path
}

locals {
  spoke_account_id = var.account_id != "" ? var.account_id : data.aws_ssm_parameter.spoke_account_id[0].value
}

provider "aws" {
  region = "us-east-2"

  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-security-hub-suppressions"
  }

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Account   = var.account_name
      Stack     = "security-hub-suppressions"
      Repo      = "lza-universal-config-hub-and-spoke"
    }
  }
}
