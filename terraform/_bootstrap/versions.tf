terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# State for the bootstrap stays local. Do NOT add a backend block here.
# Commit *.tf, never *.tfstate.
