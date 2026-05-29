# Terraform Rollout Guide

Audience: LZA operator for `thenew-aws-accelerator-config`.
Goal: stand up the Terraform side cleanly, end to end, without breaking the existing LZA pipeline or the live CFN stacks (`IngressALB`, `ScriptcaseLB`, `ScriptcaseGA`).

> Read this end-to-end before touching anything. The order matters — the LZA pipeline run in Step 2 is the prerequisite for everything else, and skipping it leads to the most common failure mode (Terraform tries to assume a role that doesn't exist yet).

---

## 0. The shape of what you're doing

Two layers, two tools:

- **LZA owns the platform**: accounts, OUs, VPCs, TGW, IPAM, Identity Center, central CloudTrail/Config/Security Hub/GuardDuty/Macie/Inspector, KMS baseline, central log buckets, SCPs/RCPs, baseline IAM.
- **Terraform owns the apps**: ALBs, WAFs scoped to those LBs, EC2/ASG/RDS, app S3 buckets, app DNS records, app ACM certs, Global Accelerator.

The credential model:

```
Human dev:    SSO login → SharedServices (TerraformDeveloper PS) → AssumeRole → spoke (TerraformExecution)
GitHub CI:    OIDC      → SharedServices (GitHubActions-Terraform) → AssumeRole → spoke (TerraformExecution)
```

No long-lived AWS keys anywhere. The trust on `TerraformExecution` is "any principal in SharedServices" — the real gate is who can land in SharedServices in the first place, controlled by Identity Center.

---

## 1. Pre-flight

What's already in this repo:

- `terraform/_bootstrap/` — runs once, creates state backend + GitHub OIDC + hub policies.
- `terraform/modules/{alb,waf-managed,ec2-migrated,global-accelerator}/` — reusable building blocks.
- `terraform/live/_template/` — copy-paste starting point for any new stack.
- `.github/workflows/terraform.yml` — CI: plan on PR, apply on merge to `main`.
- `thenew-aws-accelerator-config/iam-policies/terraform-execution-policy.json` — what Terraform can do in spokes.
- `thenew-aws-accelerator-config/iam-config.yaml` — wires up the policy + `TerraformExecution` role in every spoke.

What you're going to do:

- [ ] Run the LZA pipeline once to provision `TerraformExecution` everywhere.
- [ ] Run `terraform/_bootstrap/` once with admin SSO into SharedServices.
- [ ] Configure two Identity Center permission sets in SharedServices.
- [ ] Add one GitHub repo secret + one GitHub environment.
- [ ] Set up your local SSO profile.
- [ ] Build a sanity-check leaf to prove the chain works end-to-end.
- [ ] Done.

What you are **not** doing:

- Not migrating `IngressALB`, `ScriptcaseLB`, or `ScriptcaseGA`. They stay as CloudFormation, owned by LZA, untouched.
- Not creating any new accounts, VPCs, or modifying `network-config.yaml`.
- Not granting Terraform the ability to mutate LZA-owned resources (the policy explicitly denies that).

### Pre-reqs

- [ ] You have **break-glass admin** access to the `Management` account.
- [ ] You can run the LZA pipeline (release change on `AWSAccelerator-Pipeline`).
- [ ] You have **Identity Center admin** access to SharedServices (the delegated admin per `iam-config.yaml`).
- [ ] You have **admin / write access** on the GitHub repo (to add secrets and create environments).
- [ ] Local tooling: `aws` CLI v2, `terraform` >= 1.6, `git`. Optional: `tflint`.
- [ ] No one else is mid-flight on a Terraform-related change in the repo.

---

## 2. Update LZA and run the pipeline

This step provisions the `TerraformExecution` role and its policy in every spoke account. Without this, no Terraform run will succeed (the role won't exist to assume).

The repo already has the changes staged in `thenew-aws-accelerator-config/`:

- `iam-policies/terraform-execution-policy.json`
- `iam-config.yaml` (adds the policy reference + the role)

### 2a. Verify the diff

Open `thenew-aws-accelerator-config/iam-config.yaml`. Confirm both blocks below are present:

```yaml
policySets:
  - deploymentTargets:
      organizationalUnits:
        - Root
      excludedAccounts:
        - Management
    policies:
      # ... existing policies ...
      - name: "{{ AcceleratorPrefix }}-Terraform-Execution-Policy"
        policy: iam-policies/terraform-execution-policy.json

roleSets:
  - deploymentTargets:
      organizationalUnits:
        - Root
      excludedAccounts:
        - Management
    roles:
      # ... existing roles ...
      - name: TerraformExecution
        assumedBy:
          - type: account
            principal: SharedServices
        policies:
          customerManaged:
            - "{{ AcceleratorPrefix }}-Terraform-Execution-Policy"
```

If anything's missing, stop and re-apply the changes before continuing.

### 2b. Zip and upload

```bash
cd thenew-aws-accelerator-config
zip -r ../aws-accelerator-config.zip . -x "*.DS_Store"
cd ..
# Upload aws-accelerator-config.zip to your LZA config bucket (the one the
# pipeline reads from, typically aws-accelerator-config-<management-id>-<region>).
```

> If you're not sure of the bucket name, look at `Source` in CodePipeline → AWSAccelerator-Pipeline. It points at the bucket.

### 2c. Run the pipeline

CodePipeline → AWSAccelerator-Pipeline → Release change.

Expected runtime: 25–40 minutes. Expected stages: Source → Build → Prepare → Accounts → Bootstrap → Logging → Organizations → SecurityAudit → Network → Operations → Security → Network/Customizations → Finalize.

The new role gets created during the **Operations** stage (IAM resources). If the pipeline fails before that stage, the failure is unrelated to these changes.

### 2d. Verify the role exists

Sign in to any spoke (e.g. `Perimeter`) and check:

```bash
aws iam get-role --role-name TerraformExecution \
  --query 'Role.{Name:RoleName,Trust:AssumeRolePolicyDocument,Created:CreateDate}' \
  --output json
```

Expected: the trust policy lists the SharedServices account ID under `Principal.AWS`. Confirm the same in two more spokes (`SharedServices` itself, and one Workloads spoke like `Production` or `Development`).

> **Gotcha**: if the role exists in SharedServices but its trust policy points at SharedServices itself, that's correct. SharedServices needs to be able to assume into itself for stacks deployed to that account.

If any spoke is missing the role, the pipeline didn't apply IAM to that account. Common reasons: the account is in an OU not covered by `Root` (it shouldn't be), or the account is in `Suspended` (intentionally excluded). Investigate before continuing.

### 2e. Verify the policy attached

```bash
aws iam list-attached-role-policies --role-name TerraformExecution
```

Expected: `AWSAccelerator-Terraform-Execution-Policy` is attached. If a different name is attached or none, re-check `iam-config.yaml` and re-run the pipeline.

---

## 3. Run the bootstrap

This step creates the state backend and the CI authentication primitives in **SharedServices**. Run it once with admin SSO into SharedServices.

> **Important**: the bootstrap state stays **local**. Do not commit `terraform.tfstate` from this directory. The `.gitignore` at `terraform/.gitignore` already excludes it.

### 3a. Get an admin session

In Identity Center (or your IdP), make sure your user is assigned a permission set with `AdministratorAccess` (or equivalent) on the SharedServices account. This is for the bootstrap step only.

```bash
aws configure sso
# SSO start URL: https://<your-org>.awsapps.com/start
# SSO region:    us-east-2
# Account:       SharedServices
# Role:          AdministratorAccess
# Profile name:  lza-shared-admin
```

Then:

```bash
aws sso login --profile lza-shared-admin
export AWS_PROFILE=lza-shared-admin
aws sts get-caller-identity   # confirm you're in SharedServices
```

### 3b. Fill in the inputs

```bash
cd terraform/_bootstrap
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
region = "us-east-2"

github_repos = [
  "your-org/lza-universal-config-hub-and-spoke"   # CHANGE: real org/repo
]
```

Pin the exact repo. **Do not** wildcard. If you have a second repo later, add it to the list and re-run.

### 3c. Apply

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Expected outputs:

- `state_bucket_name` → `lza-terraform-state-<sharedservices-account-id>`
- `lock_table_name` → `lza-terraform-locks`
- `kms_key_alias` → `alias/lza-terraform-state`
- `github_actions_role_arn` → `arn:aws:iam::<sharedservices-id>:role/GitHubActions-Terraform`
- `developer_policy_arn` → ARN of `TerraformDeveloperHubAccess`
- `readonly_policy_arn` → ARN of `TerraformReadOnlyHubAccess`

**Save these.** You'll paste several into other places. Especially `state_bucket_name` and `github_actions_role_arn`.

### 3d. Verify

```bash
# Bucket
aws s3api head-bucket --bucket "$(terraform output -raw state_bucket_name)"
aws s3api get-bucket-versioning --bucket "$(terraform output -raw state_bucket_name)"
# expected: Status=Enabled

# Lock table
aws dynamodb describe-table --table-name lza-terraform-locks \
  --query 'Table.{Status:TableStatus,SSE:SSEDescription.Status}'
# expected: Status=ACTIVE, SSE=ENABLED

# OIDC provider
aws iam list-open-id-connect-providers
# expected: at least one provider whose URL ends with token.actions.githubusercontent.com
```

If anything's off, re-run `terraform plan` to see the drift, fix, re-apply.

### 3e. Drop your admin session

```bash
unset AWS_PROFILE
```

You won't need it again unless you re-run bootstrap. From this point, normal Terraform work uses the `TerraformDeveloper` permission set, which has far less power.

---

## 4. Set up Identity Center permission sets

Sign in to **SharedServices** (the Identity Center delegated admin) → IAM Identity Center.

You're creating two permission sets that wrap the customer-managed policies the bootstrap created. Both go in SharedServices; users assume them and from there role-chain into spokes.

### 4a. Create `TerraformDeveloper`

IAM Identity Center → Permission sets → Create permission set.

- Type: **Custom permission set**
- Name: `TerraformDeveloper`
- Session duration: 8 hours (enough for a working day, short enough that creds rotate frequently)
- Attach policies:
  - **Customer managed policies** (NOT AWS-managed): add `TerraformDeveloperHubAccess` (the name created by bootstrap; the ARN was in `developer_policy_arn`)
- Permissions boundary: leave empty (the policy's deny statements are the boundary)

Click create.

### 4b. Create `TerraformReadOnly`

Same flow.

- Name: `TerraformReadOnly`
- Customer managed policy: `TerraformReadOnlyHubAccess`
- Session duration: 8 hours

### 4c. Assign permission sets to a group

If you don't already have a group, create one (e.g. `engineering-terraform`) and add the relevant users.

IAM Identity Center → AWS accounts → select **SharedServices** → Assign users or groups → pick your group → assign the `TerraformDeveloper` permission set. (Repeat for `TerraformReadOnly` if you want a broader audience to be able to `plan`.)

### 4d. Verify

A team member (or you) signs out and back in to the Identity Center portal. They should see SharedServices with the new permission sets available.

> **Gotcha**: customer-managed policies referenced in a permission set must exist in **every account where the permission set is assigned**. We're only assigning to SharedServices, where the bootstrap created them, so this works. If you ever assign these permission sets to additional accounts, the policies must exist there too — but you don't need to, because the whole point is that everyone lands in SharedServices first.

---

## 5. Configure the GitHub repo

### 5a. Add the repo secret

GitHub → repo → Settings → Secrets and variables → Actions → New repository secret.

- Name: `AWS_TF_ROLE_ARN`
- Value: the `github_actions_role_arn` output from bootstrap (e.g. `arn:aws:iam::<sharedservices-id>:role/GitHubActions-Terraform`)

This is the role GitHub Actions assumes via OIDC. It's not a secret in the traditional sense (it's an ARN, not a credential), but storing it as a secret keeps the workflow file tidy.

### 5b. Create the `production` environment

GitHub → repo → Settings → Environments → New environment.

- Name: `production`
- **Required reviewers**: add at least one person other than the typical PR author. This gates `apply`.
- Wait timer: 0 (optional — set to 5–10 min if you want a "second look" cooling-off).
- Deployment branches: restrict to `main`.

The workflow already references `environment: production` for the apply job, so this gate kicks in automatically.

### 5c. Confirm OIDC trust

The bootstrap pinned the OIDC trust to:

- `repo:<your-org>/<repo>:ref:refs/heads/main` (for apply)
- `repo:<your-org>/<repo>:pull_request` (for plan on PRs)
- `repo:<your-org>/<repo>:environment:production` (for environment-gated runs)

If your repo name in `terraform.tfvars` was wrong, the trust won't match and the workflow will fail with `not authorized to perform sts:AssumeRoleWithWebIdentity`. Fix the bootstrap tfvars and re-run `terraform apply` in `_bootstrap/`.

---

## 6. Local developer setup (one-time per developer)

Each developer who'll run Terraform locally needs an SSO profile pointing at SharedServices with the `TerraformDeveloper` permission set.

```bash
aws configure sso
# SSO start URL: https://<your-org>.awsapps.com/start
# SSO region:    us-east-2
# Account:       SharedServices
# Role:          TerraformDeveloper
# Profile name:  lza-tooling
# Default region: us-east-2
# Default output: json
```

Daily flow:

```bash
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling
aws sts get-caller-identity   # should show SharedServices + TerraformDeveloper
```

That's it. The provider chain in every leaf re-assumes from SharedServices into the target spoke automatically.

> **Read-only access** for less-privileged team members: same flow but use the `TerraformReadOnly` permission set. Plan works; apply fails with `AccessDenied` on state writes. That's the desired outcome.

---

## 7. Build the sanity-check leaf

You'll prove the whole chain works before deploying anything real. We'll build a no-cost leaf — just an SSM parameter — and watch it deploy via CI.

### 7a. Copy the template

```bash
cp -r terraform/live/_template terraform/live/sharedservices/sanity-check
```

### 7b. Edit the four files

`terraform/live/sharedservices/sanity-check/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "lza-terraform-state-<sharedservices-account-id>"   # CHANGE
    key            = "live/sharedservices/sanity-check/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lza-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/lza-terraform-state"
  }
}
```

`terraform/live/sharedservices/sanity-check/main.tf`:

```hcl
resource "aws_ssm_parameter" "sanity_check" {
  name        = "/apps/sanity-check/hello"
  type        = "String"
  value       = "hello from terraform via ${var.account_name}"
  description = "Proves the LZA→Terraform credential chain works."
}

output "param_name"  { value = aws_ssm_parameter.sanity_check.name }
output "param_value" { value = aws_ssm_parameter.sanity_check.value }
```

Create `terraform/live/sharedservices/sanity-check/terraform.tfvars` (gitignored, but everyone runs locally so this is fine for a sanity check):

```hcl
account_name = "SharedServices"
stack_name   = "sanity-check"
region       = "us-east-2"
```

> Production leaves should not check in `.tfvars`. For this sanity check we're fine because the values are non-sensitive.

### 7c. Local plan

```bash
cd terraform/live/sharedservices/sanity-check
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

terraform init
terraform plan
```

Expected: `Plan: 1 to add, 0 to change, 0 to destroy.`

If you see `error reading SSM parameter ...spoke_account_id`, the LZA pipeline didn't publish the account ID. Check `/accelerator/organization/account-ids/SharedServices` exists in SharedServices via SSM console.

### 7d. Push and let CI run it

Don't apply locally — the whole point is to validate the CI path.

```bash
git checkout -b sanity-check-tf
git add terraform/live/sharedservices/sanity-check
git commit -m "Add Terraform sanity-check leaf"
git push -u origin sanity-check-tf
```

Open the PR. CI should:

1. Run `terraform fmt -check`, `validate`, `plan` for the new leaf.
2. Post a sticky PR comment with the plan output (1 to add).

If that works, merge the PR. The `apply` job should:

3. Wait at the `production` environment gate for a reviewer.
4. After approval, run `terraform apply -auto-approve`.

Verify in AWS console: SSM Parameter Store → `/apps/sanity-check/hello` exists with the expected value.

### 7e. Tear it down

```bash
cd terraform/live/sharedservices/sanity-check
terraform destroy
git rm -r terraform/live/sharedservices/sanity-check
git commit -m "Remove sanity-check leaf"
git push
```

(The destroy can also be done via `terraform destroy` locally; the CI workflow only runs `apply`, not `destroy`. Removing the directory in a PR causes CI to no-op for that leaf since detection is path-based.)

---

## 8. The "first real leaf" playbook

Once the sanity check passes, every new stack follows this exact pattern.

```bash
# 1. Pick a name and an account
ACCOUNT=Perimeter
STACK=my-new-alb

# 2. Copy the template
cp -r terraform/live/_template terraform/live/${ACCOUNT,,}/$STACK

# 3. Edit backend.tf - update the key path
sed -i '' "s|live/__account__/__stack__|live/${ACCOUNT,,}/$STACK|" \
  terraform/live/${ACCOUNT,,}/$STACK/backend.tf
sed -i '' "s|<sharedservices-account-id>|<your-real-id>|" \
  terraform/live/${ACCOUNT,,}/$STACK/backend.tf

# 4. Write main.tf using modules from terraform/modules/
#    See module READMEs for examples.

# 5. Local plan
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling
cd terraform/live/${ACCOUNT,,}/$STACK
terraform init
terraform plan

# 6. PR, plan-comment review, merge, environment-gated apply.
```

Always read the IDs from SSM, never hardcode. Examples:

```hcl
data "aws_ssm_parameter" "vpc_id"   { name = "/accelerator/network/vpc/Network-Endpoints/id" }
data "aws_ssm_parameter" "public_a" { name = "/accelerator/network/vpc/Network-Endpoints/subnet/Network-Endpoints-A/id" }
data "aws_ssm_parameter" "public_b" { name = "/accelerator/network/vpc/Network-Endpoints/subnet/Network-Endpoints-B/id" }
```

The exact path depends on what your `network-config.yaml` named the VPC. Browse SSM in the target account once to confirm the names.

---

## 9. The boundary — what Terraform must never do

The `terraform-execution-policy.json` enforces this technically, but writing it down here so reviewers can spot bad PRs.

**Terraform never**:

- Modifies VPCs, subnets, route tables, IGWs, NAT GWs, TGW, IPAM, VPC endpoints, NACLs, or VPC flow logs (LZA owns network).
- Calls `organizations:*`, `account:*`, `controltower:*`, `sso:*`, `identitystore:*` (LZA owns org/identity).
- Touches central CloudTrail, AWS Config recorder, Security Hub, GuardDuty, Macie, Inspector, central Backup vaults (LZA owns security baseline).
- Writes to `/accelerator/*` SSM parameters (LZA publishes those; Terraform reads only).
- Mutates resources tagged `Accelerator=AWSAccelerator` (LZA-managed; deny-by-tag in the policy).
- Touches roles named `AWSAccelerator-*`, `aws-controltower-*`, `AWSControlTowerExecution`, `AWSCloudFormationStackSetExecutionRole`, `cdk-accel-*` (LZA pipeline roles).

If a Terraform leaf needs one of the above, it's signalling that the change belongs in LZA, not Terraform. Move it.

**Terraform does**:

- Create app-layer load balancers, target groups, listeners, listener rules.
- Create WAFs scoped to those LBs.
- Create EC2 instances, ASGs, launch templates, ECS services, Lambda functions.
- Create app-owned RDS, ElastiCache, OpenSearch, S3 buckets, DynamoDB tables.
- Create Route53 records on app zones; ACM certs for app hostnames.
- Create app-scoped CloudFront distributions, API Gateways, Global Accelerators.
- Create app-scoped CloudWatch log groups, metrics, alarms.

When in doubt: if removing the resource breaks the platform for everyone, it's LZA. If it only breaks one app, it's Terraform.

---

## 10. Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `error reading SSM parameter /accelerator/organization/account-ids/<X>` | LZA pipeline hasn't run since the account was added; or account not in `accounts-config.yaml`. | Run LZA pipeline. Confirm SSM param exists in SharedServices. |
| `AccessDenied: User: ... is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::<spoke>:role/TerraformExecution` | LZA pipeline hasn't created the role yet. | Run LZA pipeline (Section 2). |
| `AccessDenied: ... is not authorized to perform: sts:AssumeRoleWithWebIdentity` (in CI) | OIDC trust mismatch — wrong repo name in `_bootstrap/terraform.tfvars`. | Fix tfvars, re-apply bootstrap. |
| `AccessDenied` on a real action inside a spoke | `terraform-execution-policy.json` denies it (might be a tag-based deny on an LZA resource, or a Deny SID). | Read the error, check the policy. If genuinely app-layer, add to allow. If touching LZA, redesign. |
| SCP block (`with an explicit deny in a service control policy`) | Spoke's OU has an SCP overriding role permissions. | Look at SCPs attached to that OU in `service-control-policies/`. Update via LZA if action is legitimately app-layer. |
| `BackendInitializationError: Failed to get existing workspaces: AccessDenied` on `terraform init` | Missing s3/kms/dynamodb perms on the state backend (`TerraformDeveloperHubAccess` issue). | Confirm the SSO permission set has the customer-managed policy attached. |
| Drift after the next LZA pipeline run | Something is dual-managed. | Find what LZA changed. Move ownership to one side. Don't fight the pipeline. |
| `terraform plan` shows nothing but `apply` complains about state lock | A previous run crashed and left a lock. | `terraform force-unlock <lock-id>` only after confirming no one else is mid-apply. |
| Plan comment doesn't post on PR | Workflow `permissions:` missing `pull-requests: write`, or fork PR (GHA blocks token writes from forks). | Run from a branch in the same repo, not a fork. |

---

## 11. Rollback playbook

You can undo every step.

### Roll back the LZA pipeline change (Step 2)

1. Revert the additions in `iam-config.yaml` (remove the `Terraform-Execution-Policy` reference and the `TerraformExecution` role block).
2. Delete `iam-policies/terraform-execution-policy.json`.
3. Re-zip, re-upload, re-run pipeline. The role and policy disappear from every spoke.

This is safe: any in-flight Terraform sessions just start failing on AssumeRole. No customer impact.

### Roll back the bootstrap (Step 3)

```bash
cd terraform/_bootstrap
export AWS_PROFILE=lza-shared-admin
aws sso login --profile lza-shared-admin
terraform destroy
```

This deletes the state bucket (after emptying), DynamoDB lock table, KMS key (30-day pending), OIDC provider, GitHub Actions role, and hub policies. Be careful — you'll lose every leaf's state too. Do this only if you genuinely want to start over.

### Roll back the GitHub config

- Remove `production` environment.
- Delete `AWS_TF_ROLE_ARN` secret.

Workflow runs will fail with missing secret; that's the desired effect.

### Roll back Identity Center permission sets

IAM Identity Center → Permission sets → delete `TerraformDeveloper` and `TerraformReadOnly`. Existing user sessions die at next refresh.

---

## 12. Day-2 operations

**Adding another GitHub repo to the OIDC trust**

```bash
cd terraform/_bootstrap
# Edit terraform.tfvars: github_repos = ["repo-1", "repo-2"]
terraform plan
terraform apply
```

**Adding a new account that joins the org**

LZA puts it in the configured OU and runs the pipeline → role appears in the new account automatically. No Terraform-side work required.

**Rotating the state-encryption KMS key**

`terraform/_bootstrap/state-backend.tf` has `enable_key_rotation = true`. AWS rotates annually. No action needed.

**Re-running bootstrap**

The bootstrap is idempotent. Re-run any time to:

- Add/remove a repo from OIDC trust
- Adjust hub policy permissions
- Recover from a manual change someone made in the console

**Promoting a CFN stack to Terraform**

Last resort, only when the CFN template needs major work. Process:

1. `terraform import` the existing resources into a new leaf — never destroy and recreate.
2. Run `terraform plan` until it shows `No changes`.
3. Remove the corresponding entry from `customizations-config.yaml`.
4. Run the LZA pipeline. CloudFormation stack disappears (LZA stops managing it); resources remain (Terraform now owns them).
5. Verify nothing changed end-to-end (DNS still resolves, listener still routes).

The IngressALB / ScriptcaseLB / ScriptcaseGA stacks are stable and don't need this. Leave them alone.

---

## 13. Final checklist

By the time you're done with this guide, every box below should be checked:

- [ ] LZA pipeline ran cleanly with the iam-config.yaml change merged (Section 2).
- [ ] `aws iam get-role --role-name TerraformExecution` works in 3+ spokes (Section 2d).
- [ ] `_bootstrap/` applied successfully; outputs saved (Section 3).
- [ ] State bucket exists, versioned, KMS-encrypted (Section 3d).
- [ ] DynamoDB lock table exists, ACTIVE, SSE on.
- [ ] OIDC provider exists in SharedServices.
- [ ] `TerraformDeveloper` and `TerraformReadOnly` permission sets exist in Identity Center (Section 4).
- [ ] At least one group is assigned them on SharedServices.
- [ ] `AWS_TF_ROLE_ARN` repo secret set (Section 5a).
- [ ] `production` GitHub environment exists with required reviewers (Section 5b).
- [ ] Local SSO profile (`lza-tooling`) configured and `aws sts get-caller-identity` works (Section 6).
- [ ] Sanity-check leaf deployed via CI end-to-end and torn down (Section 7).
- [ ] Existing CFN stacks (`IngressALB`, `ScriptcaseLB`, `ScriptcaseGA`) unchanged in `customizations-config.yaml`.

When all 13 boxes are checked, you're production-ready. Every new app-layer stack from this point on is a `cp -r terraform/live/_template ...`, edit, PR, merge.

---

## 14. References

- `terraform/README.md` — operating contract, layout, command reference.
- `terraform/_bootstrap/README.md` — bootstrap-specific notes.
- `terraform/modules/*/README.md` — module-specific usage.
- `terraform-vs-lza.md` — boundary in one sentence (top of repo).
- `account-decommission-guide.md` — how the suspend/recover model interacts with Terraform (suspended accounts have `TerraformExecution` removed via `ignore: true`; reactivation re-creates it on the next LZA run).
- LZA docs: https://awslabs.github.io/landing-zone-accelerator-on-aws/latest/user-guide/config/
- AWS OIDC provider for GitHub Actions: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
