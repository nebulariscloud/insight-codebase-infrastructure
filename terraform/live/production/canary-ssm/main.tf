###############################################################################
# Canary leaf: proves the full Terraform pipeline against a real spoke.
#
# Creates one SSM parameter in Production. Cheap, reversible, no real-world
# side effects. Once green CI plan + apply lands, you can rip this leaf out
# (delete the directory in a follow-up PR — Terraform will destroy the param).
###############################################################################

resource "aws_ssm_parameter" "canary" {
  name        = "/canary/terraform-pipeline"
  description = "Canary parameter to verify the Terraform CI pipeline reaches Production."
  type        = "String"
  value       = "ok"
}

output "canary_parameter_name" {
  description = "Name of the SSM parameter created by the canary."
  value       = aws_ssm_parameter.canary.name
}

output "canary_parameter_arn" {
  description = "ARN of the SSM parameter created by the canary."
  value       = aws_ssm_parameter.canary.arn
}
