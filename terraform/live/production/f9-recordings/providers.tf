###############################################################################
# Tooling provider runs in SharedServices (where SSO or the GitHubActions
# role lands). The default provider re-assumes TerraformExecution in the
# Production spoke and is what every aws_* resource in this leaf uses.
###############################################################################

provider "aws" {
  alias  = "tooling"
  region = var.region
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-${var.stack_name}"
  }

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Account   = var.account_name
      Stack     = var.stack_name
      Repo      = "insight-codebase-infrastructure"
    }
  }
}
