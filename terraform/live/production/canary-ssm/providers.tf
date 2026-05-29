###############################################################################
# Tooling provider runs in SharedServices (where the GitHubActions-Terraform
# role assumed). The default provider re-assumes TerraformExecution in the
# Production spoke.
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
