# Live stack template

Copy this directory to `terraform/live/<account>/<stack-name>/`, then:

1. Edit `backend.tf` — set `key = "live/<account>/<stack-name>/terraform.tfstate"`.
2. Edit `terraform.tfvars` — set `account_name`, `stack_name`, `region`.
3. Replace the placeholder content in `main.tf` with your modules / resources.
4. `terraform init` (CI does this on PR too).
5. `terraform plan` — confirm the diff is what you expect.
6. Open a PR. Merge to apply.

Everything except `terraform.tfvars` is committed. `terraform.tfvars` for any leaf with secrets stays in Secrets Manager / SSM and is read via data sources.
