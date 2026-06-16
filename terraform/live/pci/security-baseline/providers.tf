###############################################################################
# Provider chain for the PCI security-baseline leaf.
#
# Step 1: aws.tooling stays in SharedServices (where the operator's SSO session
#         or GitHub OIDC role lands). Used to read SSM parameters that LZA
#         publishes plus the SecureString holding the security contact phone.
#
# Step 2: Each regional provider (aws.use1, aws.use2, aws.usw2) and the default
#         provider re-assume into the PCI account using the TerraformExecution
#         role. The module's region-scoped resources reference the aliases;
#         account-level resources use the default provider.
#
# Account ID resolution: prefer var.account_id when explicitly set; otherwise
# read /accelerator/organization/account-ids/PCI from SSM. This mirrors the
# project-wide template at terraform/live/_template/providers.tf.
###############################################################################

provider "aws" {
  alias  = "tooling"
  region = "us-east-2"
}

# Resolve the PCI account ID from SSM unless overridden.
data "aws_ssm_parameter" "spoke_account_id" {
  count    = var.account_id == "" ? 1 : 0
  provider = aws.tooling
  name     = var.account_id_ssm_path
}

# Read the security contact phone from SharedServices SSM SecureString.
data "aws_ssm_parameter" "security_contact_phone" {
  provider        = aws.tooling
  name            = var.security_contact_phone_ssm_path
  with_decryption = true
}

locals {
  spoke_account_id = var.account_id != "" ? var.account_id : data.aws_ssm_parameter.spoke_account_id[0].value

  assume_role_arn = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"

  default_tags = {
    ManagedBy = "Terraform"
    Account   = var.account_name
    Stack     = "security-baseline"
    Repo      = "lza-universal-config-hub-and-spoke"
  }
}

###############################################################################
# Default provider — used by account-level resources in the module
# (aws_account_alternate_contact, aws_iam_role).
# Region must be the home region; the actual region is irrelevant for these.
###############################################################################

provider "aws" {
  region = "us-east-2"

  assume_role {
    role_arn     = local.assume_role_arn
    session_name = "tf-${var.account_name}-security-baseline"
  }

  default_tags { tags = local.default_tags }
}

###############################################################################
# Regional providers — used for region-scoped resources in the module.
###############################################################################

provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  assume_role {
    role_arn     = local.assume_role_arn
    session_name = "tf-${var.account_name}-security-baseline"
  }

  default_tags { tags = local.default_tags }
}

provider "aws" {
  alias  = "use2"
  region = "us-east-2"

  assume_role {
    role_arn     = local.assume_role_arn
    session_name = "tf-${var.account_name}-security-baseline"
  }

  default_tags { tags = local.default_tags }
}

provider "aws" {
  alias  = "usw2"
  region = "us-west-2"

  assume_role {
    role_arn     = local.assume_role_arn
    session_name = "tf-${var.account_name}-security-baseline"
  }

  default_tags { tags = local.default_tags }
}
