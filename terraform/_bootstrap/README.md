# Bootstrap — run this once

This creates everything Terraform needs to operate before any `live/` stack can run:

- KMS key + alias `lza-terraform-state` (encrypts state at rest)
- S3 bucket `lza-terraform-state-<account-id>` (Terraform state, versioned, SSE-KMS, public access blocked)
- DynamoDB table `lza-terraform-locks` (state locking)
- IAM OIDC provider for `token.actions.githubusercontent.com`
- IAM role `GitHubActions-Terraform` (assumed by GitHub Actions via OIDC)
- IAM role `TerraformDeveloperHub` (assumed by humans via Identity Center; this is the SharedServices-side role, not the per-spoke one)

It runs in **SharedServices**. State for this bootstrap stays **local** (committed file is only the `.tf`, never `terraform.tfstate`). After this runs, every other leaf uses the S3 backend it created.

---

## Pre-reqs

- LZA pipeline has run at least once and the `TerraformExecution` role exists in every spoke (this is provisioned by `iam-config.yaml` `roleSets`).
- You have admin access to SharedServices via Identity Center (`AdministratorAccess` permission set or equivalent).
- You know your GitHub org/repo name (e.g. `your-org/lza-universal-config-hub-and-spoke`).

---

## Run procedure

```bash
cd terraform/_bootstrap

# Get an admin session in SharedServices
aws sso login --profile lza-shared-admin   # configure once with `aws configure sso`
export AWS_PROFILE=lza-shared-admin

# Fill in the inputs
cp example.tfvars terraform.tfvars
# edit terraform.tfvars — set github_repo

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

After this completes, save the outputs (`state_bucket_name`, `github_actions_role_arn`, `kms_key_alias`). You'll paste them into the backend blocks of every `live/` leaf.

---

## What if I need to add another repo to the OIDC trust later?

Re-run `_bootstrap/`:

```bash
# Add the second repo to terraform.tfvars
github_repos = ["your-org/lza-universal-config-hub-and-spoke", "your-org/another-repo"]

terraform plan
terraform apply
```

That's it. State for the bootstrap stays local; commit only the `terraform.tfstate.backup` to make `apply` reproducible — actually, **don't commit any state file**. Keep one copy in 1Password / Bitwarden, or re-run bootstrap if you lose it (it's idempotent).

---

## Why local state for bootstrap

You can't store state in a bucket you haven't created yet. People work around this with two-step bootstraps; for a tiny bootstrap that runs once or twice a year, local state is simpler and safer than building a second backend just to host the first one's state.
