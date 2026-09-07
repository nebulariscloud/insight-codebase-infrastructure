###############################################################################
# Provider chain for the Audit account security-hub-suppressions leaf.
#
# The Audit account is the Security Hub delegated administrator for the
# organization (set via centralSecurityServices.delegatedAdminAccount: Audit
# in aws-accelerator-config/security-config.yaml). Automation rules created
# here apply to all member accounts centrally.
#
# Step 1: aws.tooling stays in SharedServices (GitHub Actions OIDC landing pad).
#         Used only to resolve the Audit account ID from SSM.
# Step 2: Default provider re-assumes TerraformExecution into Audit.
#
# Security Hub automation rules are global (not region-scoped) when region
# aggregation is enabled, so a single us-east-2 provider is sufficient.
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
      Repo      = "insight-codebase-infrastructure"
    }
  }
}
