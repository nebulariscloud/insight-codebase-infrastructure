# Terraform — App-Layer Infrastructure

This directory holds Terraform code that complements LZA. LZA owns the platform; Terraform owns everything that lives on top of it.

The point of this split is iteration speed. The LZA pipeline takes ~30 minutes and is the right tool for accounts, OUs, VPCs, TGW, IAM baseline, central security services, and SCPs. It is the wrong tool for spinning up a load balancer, swapping a cert, or registering EC2 targets. Those go here, and a `terraform apply` finishes in under a minute.

---

## Ownership boundary

The single rule: **LZA owns the platform, Terraform owns the apps. Terraform never mutates anything LZA created — it only reads it.**

| Layer | Owned by | Examples |
|---|---|---|
| Org structure | LZA | Accounts, OUs |
| Network platform | LZA | VPCs, TGW, IPAM, central route tables, VPC endpoints |
| Security baseline | LZA | Config, Security Hub, GuardDuty, Macie, central CloudTrail, central KMS, central log buckets |
| Identity baseline | LZA | Identity Center, baseline IAM roles, permission boundaries, SCPs/RCPs |
| App load balancers | Terraform | ALB, NLB, target groups, listener rules |
| App WAFs | Terraform | WebACLs scoped to app LBs |
| Compute | Terraform | EC2, ASG, ECS, Lambda |
| Data stores (app-owned) | Terraform | RDS, ElastiCache, app-owned S3 buckets, app-owned DynamoDB |
| App DNS / certs | Terraform | Route53 records on app zones, ACM certs for app hostnames |
| App messaging | Terraform | SQS, SNS topics for app use, EventBridge buses for app use |
| Edge | Terraform | CloudFront, Global Accelerator, app-scoped API Gateway |

When in doubt: if removing a thing would break the *platform* for everyone, it's LZA. If removing it only breaks one app, it's Terraform.

### What you read, what you don't touch

LZA publishes resource IDs to SSM Parameter Store under `/accelerator/*`. Read these in Terraform with `data "aws_ssm_parameter"`. Examples:

```
/accelerator/network/vpc/<vpc-name>/id
/accelerator/network/vpc/<vpc-name>/subnet/<subnet-name>/id
/accelerator/network/vpc/<vpc-name>/securityGroup/<sg-name>/id
/accelerator/kms/<key-name>/key-arn
/accelerator/organization/account-ids/<AccountName>
```

The `terraform-execution-policy.json` explicitly **denies write** to `/accelerator/*` parameters. That's the technical fence around the rule above.

Existing CloudFormation stacks (`IngressALB`, `ScriptcaseLB`, `ScriptcaseGA`, etc., defined in `thenew-aws-accelerator-config/customizations-config.yaml`) stay where they are. New things go to Terraform. If/when you migrate one, use `terraform import` so the resources keep their existing ARNs and DNS names.

---

## Credential model

No long-lived access keys, anywhere, ever. Two paths, one destination.

```
[Local: human dev]                         [CI: GitHub Actions]
       │                                          │
   aws sso login                       AssumeRoleWithWebIdentity (OIDC)
       │                                          │
       ▼                                          ▼
 Identity Center                           GitHubActions-Terraform
   permission set                            role in SharedServices
 (in SharedServices)                                │
       └────────────────┬─────────────────────────┘
                        │
                  sts:AssumeRole
                        │
                        ▼
            TerraformExecution role
            in the target spoke account
                        │
                        ▼
               actually does the work
```

The hub is **SharedServices** (which is also your Identity Center delegated admin per `iam-config.yaml`). Both the human SSO session and the GitHub OIDC role land in SharedServices, then chain into each spoke.

### Roles, where they come from

| Role | Where | Created by |
|---|---|---|
| `TerraformExecution` | Every spoke (Workloads + Infra OUs, excluding Management) | LZA via `iam-config.yaml` `roleSets` |
| `TerraformDeveloper` permission set | Identity Center | Manually in IAM Identity Center console (or your IdP-side automation) |
| `TerraformReadOnly` permission set | Identity Center | Same |
| `GitHubActions-Terraform` | SharedServices | `_bootstrap/` Terraform (run once with admin creds) |

The trust policy on `TerraformExecution` only trusts the SharedServices account ID. Whoever can assume a role in SharedServices that has `sts:AssumeRole` on `TerraformExecution` can deploy. That's where you gate access.

### Local dev setup (one-time)

1. Have your IdP/SSO admin assign you the `TerraformDeveloper` permission set in SharedServices (for `apply`) or `TerraformReadOnly` (for `plan` only).
2. Configure the AWS profile:

   ```bash
   aws configure sso
   ```

   Use:
   - SSO start URL: your Identity Center start URL (`https://<your-org>.awsapps.com/start`)
   - SSO region: `us-east-2`
   - Account: SharedServices
   - Role: `TerraformDeveloper` or `TerraformReadOnly`
   - Profile name: `lza-tooling`

3. Daily flow:

   ```bash
   aws sso login --profile lza-tooling
   export AWS_PROFILE=lza-tooling
   cd terraform/live/perimeter/<thing>
   terraform init
   terraform plan
   ```

   Each leaf's `provider.tf` re-assumes from SharedServices into the target spoke. You don't switch profiles when moving between leaves — the provider does it for you.

### CI setup (one-time, after `_bootstrap/` runs)

Pin the OIDC trust policy to one repo and one branch (or `environment:`). Don't wildcard.

```yaml
# .github/workflows/terraform.yml
permissions:
  id-token: write    # required for OIDC
  contents: read
  pull-requests: write    # for plan comments

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<sharedservices-id>:role/GitHubActions-Terraform
          aws-region: us-east-2
      - uses: hashicorp/setup-terraform@v3
      - run: terraform -chdir=terraform/live/perimeter/scriptcase-lb init
      - run: terraform -chdir=terraform/live/perimeter/scriptcase-lb plan -no-color
```

`apply` should run only on `main` after merge, never on PRs. Gate it with a GitHub `environment` that requires reviewer approval if you want a second pair of eyes before each apply.

---

## Layout

```
terraform/
├── README.md                       # this file
├── .gitignore
├── _bootstrap/                     # run once, with admin creds, never again
│   ├── README.md
│   ├── state-backend.tf            # S3 bucket + DDB lock table
│   ├── github-oidc.tf              # OIDC provider + GitHubActions-Terraform role
│   └── variables.tf
├── modules/                        # reusable building blocks
│   ├── alb/
│   ├── waf-managed/
│   ├── ec2-migrated/
│   └── global-accelerator/
└── live/                           # one folder per stack, one state file each
    ├── perimeter/
    │   ├── ingress-alb/
    │   ├── scriptcase-lb/
    │   └── scriptcase-ga/          # provider region us-west-2
    ├── shared-prod/
    │   └── alfresco/
    └── pci/
        └── pci-alb/
```

Why this shape:

- **One state file per leaf** keeps blast radius small. Applying the Scriptcase ALB never touches the ingress ALB.
- **`live/<account>/`** makes the target account obvious from the path. No "wait, which account is this".
- **`modules/`** is shared. Your existing `ingress-alb.yaml` and `scriptcase-lb.yaml` are 90% the same template. As Terraform modules, that duplication goes away.
- **`_bootstrap/`** stays separate. Don't put state config inside the same backend it's bootstrapping.

---

## Backend convention

Every leaf uses the same backend, with a unique key:

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket         = "lza-terraform-state-<sharedservices-account-id>"
    key            = "live/perimeter/scriptcase-lb/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lza-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/lza-terraform-state"
  }
}
```

Pin Terraform `>= 1.6` and the AWS provider with `~> 5.60` (or whatever you settle on). Run `terraform providers lock` and commit `.terraform.lock.hcl` per leaf so CI gets the same provider hashes you tested with.

---

## Provider convention

Every leaf has the same shape. Vary `account_name` and `region`.

```hcl
data "aws_ssm_parameter" "spoke_account_id" {
  provider = aws.tooling
  name     = "/accelerator/organization/account-ids/${var.account_name}"
}

provider "aws" {
  alias  = "tooling"
  region = var.region
}

provider "aws" {
  region = var.region
  assume_role {
    role_arn     = "arn:aws:iam::${data.aws_ssm_parameter.spoke_account_id.value}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-${var.stack_name}"
  }
  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Stack     = var.stack_name
      Account   = var.account_name
      Repo      = "lza-universal-config-hub-and-spoke"
    }
  }
}
```

You log into SharedServices once (SSO or OIDC), and the `aws.tooling` provider stays there to read the account ID from SSM. The default provider re-assumes into the spoke with that ID. Account IDs never appear in code.

---

## Security defaults (non-negotiable)

- Encrypt state at rest with KMS (the `_bootstrap/` step creates the alias `lza-terraform-state`).
- Versioning on the state bucket — recovery from "oops, applied with stale state".
- DynamoDB lock table — prevents two people running `apply` simultaneously.
- Bucket policy denies all access except the `TerraformDeveloper` SSO role and `GitHubActions-Terraform`.
- CloudTrail data events enabled on the state bucket (you already have org trail; this just adds data events).
- No `*.tfvars` in git. Use SSM/Secrets Manager `data` sources for any sensitive input.
- Pin module versions if you ever pull from registries (`source = "terraform-aws-modules/alb/aws"` → `version = "9.11.0"`).
- Run `terraform fmt -recursive` and `terraform validate` in CI on every PR.
- Add `tflint` and `checkov` (or `tfsec`) to CI for static analysis.

---

## Day-to-day commands

```bash
# Pick up the leaf you want to work in
cd terraform/live/perimeter/scriptcase-lb

# Once per machine
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

# Standard cycle
terraform init
terraform plan -out tfplan
terraform apply tfplan

# Bring an existing CFN-managed resource under TF
terraform import 'aws_lb.this' arn:aws:elasticloadbalancing:us-east-2:<acct>:loadbalancer/app/scriptcase-lb/1e9fb498cb0ab723

# Sanity check after a change
terraform plan    # should be "No changes"
```

For destroy, prefer `terraform destroy -target=...` over a full destroy unless you mean it. Most leaves should never be destroyed wholesale.

---

## When to use this vs LZA

If your change touches any of these, it's an LZA pipeline run:

- Adding/removing an account or OU
- Changing VPC, TGW, or IPAM config
- Modifying central CloudTrail / Config / Security Hub / GuardDuty
- Editing SCPs, RCPs, or permission boundaries
- Adding/removing a Control Tower control

Everything else is Terraform.

---

## Adding a new stack — the playbook

1. `mkdir terraform/live/<account-name>/<stack-name>`
2. Copy `provider.tf`, `backend.tf`, and `variables.tf` from a sibling stack. Update `key`, `account_name`, `stack_name`.
3. Add `main.tf` using a module from `terraform/modules/` or vanilla resources.
4. `terraform init && terraform plan` locally.
5. Open a PR. CI runs `plan` and posts the diff.
6. Merge. CI runs `apply` against `main`.
7. Outputs (DNS names, ARNs) become inputs for the next stack via `data "aws_ssm_parameter"` if you publish them, or `terraform_remote_state` if a tightly coupled stack needs them.

---

## Bootstrap (first time only)

The `_bootstrap/` Terraform creates the state backend and the GitHub OIDC role. It runs against SharedServices with a human admin session (Identity Center `AdministratorAccess` permission set), and it stores its **own** state locally — never in the bucket it just created. Commit only the `*.tf`, not the `terraform.tfstate` file.

See `_bootstrap/README.md` for the run procedure.

After the bootstrap, every other leaf uses the S3 backend. Bootstrap itself you can re-run if you ever need to add an OIDC trust for another repo, or rotate the KMS key, but it should be a rare event.

---

## What this replaces

In `customizations-config.yaml`, the commented-out blocks for `PciAlb`, `migrated-ec2.yaml` examples, and any future ALB / EC2 / WAF additions should land here as Terraform leaves instead. The existing live stacks (`IngressALB`, `ScriptcaseLB`, `ScriptcaseGA`) stay as CloudFormation. We don't migrate stable things just for tidiness.

---

## Troubleshooting

**`AccessDenied` on `sts:AssumeRole TerraformExecution`** — your SSO role in SharedServices doesn't have permission to assume into the spoke. Add `sts:AssumeRole` on `arn:aws:iam::*:role/TerraformExecution` to the `TerraformDeveloper` Identity Center permission set.

**`AccessDenied` on a real action inside the spoke** — the `terraform-execution-policy.json` denies it. Check the `Deny*` SIDs. If the action is genuinely app-layer and got missed, add it to the allow list and re-run the LZA pipeline. Don't widen the `Deny` boundaries.

**SCP block on action** — the spoke's OU has an SCP that overrides the role's permissions. Look at the SCPs attached to that OU in `thenew-aws-accelerator-config/service-control-policies/`. Same answer: if it's legitimately app-layer, update the SCP via LZA.

**Drift after LZA pipeline run** — something is dual-managed. Find what LZA changed (check the LZA pipeline diff) and decide who owns it. Adjust the boundary; don't fight the pipeline.
