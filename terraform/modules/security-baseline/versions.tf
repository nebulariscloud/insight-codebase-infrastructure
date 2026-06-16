terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"

      # Consumers must pass three regional providers, one per active region.
      # Region-scoped resources in this module reference these aliases explicitly
      # rather than via for_each (which cannot select providers dynamically).
      configuration_aliases = [
        aws.use1, # us-east-1
        aws.use2, # us-east-2 (also the home region for account-level resources)
        aws.usw2, # us-west-2
      ]
    }
  }
}
