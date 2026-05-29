tflint {
  required_version = ">= 0.50"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Catch missing variable types and undocumented variables
rule "terraform_typed_variables" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs"   { enabled = true }
rule "terraform_required_version"      { enabled = true }
rule "terraform_required_providers"    { enabled = true }
rule "terraform_unused_declarations"   { enabled = true }

# AWS-specific: deprecated instance types, invalid AMIs, etc.
rule "aws_instance_invalid_type" { enabled = true }
