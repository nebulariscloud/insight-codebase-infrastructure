# Design Document — Security Baseline Terraform Module

## Metadata

| Field | Value |
|---|---|
| Document version | 1.0 |
| Last review | 2026-06-15 |
| Document owner | Cloud Platform / Security |
| Parent strategy | `.kiro/specs/security-hub-findings-remediation-strategy/design.md` |
| Wave 1 target | PCI account |
| Active regions | `us-east-1`, `us-east-2`, `us-west-2` |
| Findings closed (Wave 1) | `SSM.7` (Critical), `EC2.182` (High), `SSM.6` (Medium), `Account.1` (Medium) |
| Out of scope | `S3.22`, `S3.23` (Management-account, see D-9 / `cloudtrail-data-events-runbook.md`) |

## Overview

This design implements `terraform/modules/security-baseline/` and the Wave 1 leaf at `terraform/live/pci/security-baseline/`. The module sets four AWS configurations that AWS Config does not model and LZA does not expose declaratively, applied per region where applicable. The leaf is a thin invocation that wires three regional AWS providers and the SharedServices tooling provider into the module.

The module is the long-term home for the `Terraform` mechanism rows in the parent strategy. New controls (Inspector once D-1 lands, future per-region service settings) extend the module by adding resources, never by restructuring it.

The design follows the patterns already established in `terraform/README.md`, `terraform/live/_template/`, and the existing modules under `terraform/modules/`. It does not introduce a new state pattern, a new credential model, or a new tagging convention.

## Architecture

### Where the work happens

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │                       SharedServices account                        │
   │                                                                     │
   │  Operator (SSO)  ─┐                                                 │
   │                   ├──> aws.tooling provider                         │
   │  GitHub OIDC    ──┘    (reads /accelerator/organization/            │
   │                              account-ids/PCI from SSM)              │
   │                                                                     │
   │           sts:AssumeRole TerraformExecution -> PCI account          │
   │                            │                                        │
   └────────────────────────────┼────────────────────────────────────────┘
                                │
                                ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │                          PCI account                                │
   │                                                                     │
   │   aws.use1 (us-east-1)   aws.use2 (us-east-2)   aws.usw2 (us-west-2)│
   │   ───────────────────    ───────────────────    ───────────────────│
   │                                                                     │
   │   ┌─────────────────────────────────────────────────────────────┐  │
   │   │ module "security-baseline"                                  │  │
   │   │                                                             │  │
   │   │  per region:                                                │  │
   │   │    aws_ssm_service_setting (SSM.7 — public sharing)         │  │
   │   │    aws_ebs_snapshot_block_public_access (EC2.182)           │  │
   │   │    aws_kms_key + alias  (CMK for SSM Automation logs)       │  │
   │   │    aws_cloudwatch_log_group  /aws/ssm/automation            │  │
   │   │    aws_ssm_service_setting (SSM.6 — automation log group)   │  │
   │   │    aws_inspector2_enabler   [feature-flagged, off]          │  │
   │   │                                                             │  │
   │   │  per account (region-agnostic, applied once via aws.use2):  │  │
   │   │    aws_iam_role  AWSServiceRoleForAmazonSSM-AutomationLogs  │  │
   │   │    aws_account_alternate_contact (Account.1, SECURITY)      │  │
   │   └─────────────────────────────────────────────────────────────┘  │
   └─────────────────────────────────────────────────────────────────────┘
```

The module receives **three configured regional providers** plus the **default provider** for account-level resources. The default provider is set to `us-east-2` (home region) inside the leaf and is the same as `aws.use2`; declaring it twice is intentional because Terraform requires both a default provider and explicit aliases to address resources unambiguously.

### File layout

```
terraform/
├── modules/
│   └── security-baseline/                    ← NEW (this spec)
│       ├── README.md                          (usage, verification, rollback)
│       ├── versions.tf                        (required_providers + configuration_aliases)
│       ├── variables.tf                       (all input variables)
│       ├── outputs.tf                         (KMS key ARNs, log group ARNs, role ARN)
│       ├── locals.tf                          (computed locals: region map, tags)
│       ├── data.tf                            (data sources: account ID, partition)
│       ├── ssm-document-public-sharing.tf     (SSM.7 — three resources)
│       ├── ebs-snapshot-public-access.tf      (EC2.182 — three resources)
│       ├── ssm-automation-logging.tf          (SSM.6 — KMS, log groups, IAM, service setting)
│       ├── account-contacts.tf                (Account.1 — single resource)
│       └── inspector.tf                       (feature-flagged, default disabled)
│
└── live/
    └── pci/                                   ← NEW (Wave 1 leaf)
        └── security-baseline/
            ├── README.md                      (per-leaf instructions)
            ├── backend.tf                     (S3 backend, key live/pci/security-baseline/...)
            ├── versions.tf                    (required_version + provider pin)
            ├── providers.tf                   (tooling + 3 regional providers)
            ├── variables.tf                   (account_name, contact fields, retention)
            ├── main.tf                        (module call with provider mapping)
            └── outputs.tf                     (re-exports)
```

### Provider mapping pattern

The module declares its provider needs in `versions.tf`:

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.use1, aws.use2, aws.usw2]
    }
  }
}
```

The leaf passes them in via `providers`:

```hcl
module "security_baseline" {
  source = "../../../modules/security-baseline"
  providers = {
    aws      = aws.use2   # default provider: home region for account-level resources
    aws.use1 = aws.use1
    aws.use2 = aws.use2
    aws.usw2 = aws.usw2
  }
  # variables...
}
```

This is the standard Terraform multi-region pattern. It does not use `for_each` over a region set — that approach cannot drive provider selection because providers must be statically declared. The cost is one explicit resource block per region per control. The benefit is correctness and clear `terraform plan` output.

### Adding a fourth region later

Two-step change:

1. Add `aws.<alias>` to the module's `configuration_aliases` and to each per-region resource block. Five lines total per resource type.
2. Add the corresponding provider alias in the leaf's `providers.tf` and pass it through the `providers` map.

No restructuring. The new region inherits the same code path.

## Components and Interfaces

### Component 1 — `versions.tf`

Pins Terraform `>= 1.6` and AWS provider `~> 5.60`, matching the project standard from `terraform/live/_template/versions.tf` and `terraform/modules/alb/versions.tf`. Declares `configuration_aliases = [aws.use1, aws.use2, aws.usw2]` so consuming leaves must pass the three regional providers explicitly.

### Component 2 — `variables.tf`

| Variable | Type | Default | Notes |
|---|---|---|---|
| `account_name` | string | (none) | Free-form label, used in tags. |
| `regions` | object | see below | Map of alias to region name; declared as object to keep provider mapping readable in tags and outputs. |
| `security_contact_name` | string | (none) | Account.1 |
| `security_contact_email` | string | (none) | Account.1 |
| `security_contact_phone` | string | (none) | Account.1, sensitive = true |
| `security_contact_title` | string | (none) | Account.1 |
| `automation_log_retention_days` | number | 365 | SSM.6 log group retention; matches LZA `cloudwatchLogRetentionInDays`. |
| `automation_log_kms_deletion_window` | number | 30 | KMS deletion window for the SSM Automation CMK. |
| `inspector_enabled` | bool | false | Feature flag, gated on D-1. |
| `inspector_resource_types` | list(string) | `[]` | Subset of `EC2`, `ECR`, `LAMBDA`, `LAMBDA_CODE`. Validation enforces valid values. |
| `inspector_regions` | list(string) | `[]` | Subset of region names. Validation enforces presence when `inspector_enabled = true`. |
| `tags` | map(string) | `{}` | Extra tags merged with module defaults. |

The `regions` object:

```hcl
variable "regions" {
  type = object({
    use1 = string  # us-east-1
    use2 = string  # us-east-2
    usw2 = string  # us-west-2
  })
  default = {
    use1 = "us-east-1"
    use2 = "us-east-2"
    usw2 = "us-west-2"
  }
}
```

### Component 3 — `data.tf`

Two data sources, both using the default provider (which is `us-east-2`, the home region):

```hcl
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
```

`account_id` is derived as `data.aws_caller_identity.current.account_id` and used in IAM ARNs and service-setting ARNs. `partition` supports future cross-partition use (gov-cloud) without code changes.

### Component 4 — `locals.tf`

```hcl
locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  default_tags = merge(
    {
      ManagedBy = "Terraform"
      Module    = "security-baseline"
      Stack     = "security-baseline"
      Account   = var.account_name
    },
    var.tags
  )

  # Single source of truth for the SSM Automation log group name.
  automation_log_group_name = "/aws/ssm/automation"

  # Single source of truth for the IAM role name SSM Automation assumes.
  automation_role_name = "AcceleratorBaseline-SSMAutomationLogging"
}
```

### Component 5 — `ssm-document-public-sharing.tf` (SSM.7)

One `aws_ssm_service_setting` per region:

```hcl
resource "aws_ssm_service_setting" "doc_public_sharing_use1" {
  provider      = aws.use1
  setting_id    = "arn:${local.partition}:ssm:${var.regions.use1}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}
# Same shape for use2 and usw2.
```

Three resource blocks total. Idempotent: subsequent applies report no changes.

### Component 6 — `ebs-snapshot-public-access.tf` (EC2.182)

One `aws_ebs_snapshot_block_public_access` per region:

```hcl
resource "aws_ebs_snapshot_block_public_access" "use1" {
  provider = aws.use1
  state    = "block-all-sharing"
}
# Same shape for use2 and usw2.
```

Three resource blocks total.

### Component 7 — `ssm-automation-logging.tf` (SSM.6)

This is the most complex component because SSM Automation logging requires a destination log group, a CMK to encrypt it, and an IAM role SSM Automation assumes to write to it.

**KMS CMK per region** — one customer-managed key per region, with key policy granting `logs.<region>.amazonaws.com` permission to encrypt and SSM Automation principals permission to use:

```hcl
resource "aws_kms_key" "automation_logs_use1" {
  provider                = aws.use1
  description             = "CMK for SSM Automation CloudWatch logs (us-east-1)"
  deletion_window_in_days = var.automation_log_kms_deletion_window
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.automation_logs_kms_use1.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "automation_logs_use1" {
  provider      = aws.use1
  name          = "alias/security-baseline-ssm-automation-logs"
  target_key_id = aws_kms_key.automation_logs_use1.id
}
```

The key policy (one `data.aws_iam_policy_document` per region):

- Allow root account full administration (standard practice; preserves break-glass).
- Allow `logs.<region>.amazonaws.com` to `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:Describe*`, scoped via `kms:EncryptionContext:aws:logs:arn` to the log group ARN in that region.
- Allow the SSM Automation IAM role (created below) to `kms:Decrypt`, `kms:GenerateDataKey*` for use during runbook execution.

**Log group per region** — `/aws/ssm/automation` encrypted with the regional CMK:

```hcl
resource "aws_cloudwatch_log_group" "automation_use1" {
  provider          = aws.use1
  name              = local.automation_log_group_name
  retention_in_days = var.automation_log_retention_days
  kms_key_id        = aws_kms_key.automation_logs_use1.arn
  tags              = local.default_tags
}
```

**IAM role for SSM Automation** — single role for the account (IAM is global), trust policy for `ssm.amazonaws.com`, permissions policy granting `logs:CreateLogStream` and `logs:PutLogEvents` on the three log group ARNs:

```hcl
resource "aws_iam_role" "automation_logging" {
  name               = local.automation_role_name
  assume_role_policy = data.aws_iam_policy_document.automation_assume.json
  tags               = local.default_tags
}

resource "aws_iam_role_policy" "automation_logging" {
  role   = aws_iam_role.automation_logging.id
  policy = data.aws_iam_policy_document.automation_logging.json
}
```

The permissions policy enumerates all three regional log group ARNs, granting only `logs:CreateLogStream` and `logs:PutLogEvents`. No wildcards on resource.

**Service setting per region** — points SSM Automation at the log group:

```hcl
resource "aws_ssm_service_setting" "automation_log_group_use1" {
  provider      = aws.use1
  setting_id    = "arn:${local.partition}:ssm:${var.regions.use1}:${local.account_id}:servicesetting/ssm/automation/cloudwatch-log-group"
  setting_value = local.automation_log_group_name

  depends_on = [aws_cloudwatch_log_group.automation_use1]
}
```

The `depends_on` guarantees the log group exists before SSM accepts the setting (otherwise SSM rejects the value at apply time).

### Component 8 — `account-contacts.tf` (Account.1)

Single resource using the default provider. Account-level setting; region is irrelevant.

```hcl
resource "aws_account_alternate_contact" "security" {
  alternate_contact_type = "SECURITY"
  name                   = var.security_contact_name
  email_address          = var.security_contact_email
  phone_number           = var.security_contact_phone
  title                  = var.security_contact_title
}
```

### Component 9 — `inspector.tf` (feature-flagged)

```hcl
locals {
  inspector_active = var.inspector_enabled && length(var.inspector_resource_types) > 0 && length(var.inspector_regions) > 0
}

resource "aws_inspector2_enabler" "use1" {
  count           = local.inspector_active && contains(var.inspector_regions, var.regions.use1) ? 1 : 0
  provider        = aws.use1
  account_ids     = [local.account_id]
  resource_types  = var.inspector_resource_types
}
# Same shape for use2 and usw2.
```

When `inspector_enabled = false`, all three resource blocks evaluate to `count = 0` and produce no plan diff.

### Component 10 — `outputs.tf`

```hcl
output "automation_log_group_name" {
  description = "CloudWatch log group used by SSM Automation in every region."
  value       = local.automation_log_group_name
}

output "automation_role_arn" {
  description = "IAM role ARN that SSM Automation assumes to write logs."
  value       = aws_iam_role.automation_logging.arn
}

output "automation_kms_key_arns" {
  description = "Map of region alias to CMK ARN for SSM Automation logs."
  value = {
    use1 = aws_kms_key.automation_logs_use1.arn
    use2 = aws_kms_key.automation_logs_use2.arn
    usw2 = aws_kms_key.automation_logs_usw2.arn
  }
}
```

No outputs for security contact fields. They are PII and stay in state, not in outputs.

### Component 11 — Wave 1 leaf at `terraform/live/pci/security-baseline/`

**`backend.tf`** — S3 backend with `key = "live/pci/security-baseline/terraform.tfstate"`, otherwise identical to `terraform/live/_template/backend.tf`.

**`providers.tf`** — diverges from the template because it needs three regional providers:

```hcl
provider "aws" {
  alias  = "tooling"
  region = "us-east-2"
}

data "aws_ssm_parameter" "spoke_account_id" {
  provider = aws.tooling
  name     = "/accelerator/organization/account-ids/PCI"
}

locals {
  spoke_account_id = data.aws_ssm_parameter.spoke_account_id.value
}

# Default provider — home region, used for account-level resources.
provider "aws" {
  alias  = "use2"
  region = "us-east-2"
  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-security-baseline"
  }
  default_tags { tags = { ManagedBy = "Terraform", Account = var.account_name, Stack = "security-baseline", Repo = "lza-universal-config-hub-and-spoke" } }
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-security-baseline"
  }
  default_tags { tags = { ManagedBy = "Terraform", Account = var.account_name, Stack = "security-baseline", Repo = "lza-universal-config-hub-and-spoke" } }
}

provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-security-baseline"
  }
  default_tags { tags = { ManagedBy = "Terraform", Account = var.account_name, Stack = "security-baseline", Repo = "lza-universal-config-hub-and-spoke" } }
}

# Default provider matches use2 (home region). Account-level resources use this.
provider "aws" {
  region = "us-east-2"
  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-security-baseline"
  }
  default_tags { tags = { ManagedBy = "Terraform", Account = var.account_name, Stack = "security-baseline", Repo = "lza-universal-config-hub-and-spoke" } }
}
```

This is verbose. It is also explicit, which matches the "no surprises" philosophy of the existing leaves. A future cleanup could extract a `_shared/providers.tf.tmpl` pattern, but that's out of scope.

**`variables.tf`** — minimal:

```hcl
variable "account_name" {
  type    = string
  default = "PCI"
}
variable "security_contact_name"  { type = string;  default = "Alex Gonzalez" }
variable "security_contact_email" { type = string;  default = "security@nebulariscloud.com" }
variable "security_contact_title" { type = string;  default = "CEO" }
```

The phone number is **not** a variable in the leaf. It lives in SharedServices SSM at `/security-baseline/security-contact-phone` (SecureString, KMS-encrypted) and is read via the `aws.tooling` provider:

```hcl
data "aws_ssm_parameter" "security_contact_phone" {
  provider        = aws.tooling
  name            = "/security-baseline/security-contact-phone"
  with_decryption = true
}
```

The module declares `security_contact_phone` as a `sensitive = true` variable, and the leaf passes the SSM lookup value into it:

```hcl
module "security_baseline" {
  # ...
  security_contact_phone = data.aws_ssm_parameter.security_contact_phone.value
}
```

This satisfies Requirement 6.4 (phone sourced from SSM), Requirement 6.6 (no `*.tfvars` or literal in source), and the existing `terraform/README.md` rule that no `*.tfvars` file is committed.

**One-time setup** — before the first `terraform apply`, create the parameter in SharedServices:

```bash
aws ssm put-parameter \
  --name /security-baseline/security-contact-phone \
  --type SecureString \
  --value '+17875863211' \
  --description "Phone number used by aws_account_alternate_contact (SECURITY type) across spokes" \
  --region us-east-2 \
  --profile lza-tooling
```

The parameter uses the default `alias/aws/ssm` KMS key. If you prefer a CMK, pass `--key-id <arn>` and grant `kms:Decrypt` on it to the `TerraformDeveloper` SSO role and the `GitHubActions-Terraform` role.

To rotate the value: `aws ssm put-parameter ... --overwrite`, then re-run `terraform apply` on each leaf to push the new value into the SECURITY alternate contact.

**`main.tf`**:

```hcl
module "security_baseline" {
  source = "../../../modules/security-baseline"

  providers = {
    aws      = aws        # default — home region (us-east-2)
    aws.use1 = aws.use1
    aws.use2 = aws.use2
    aws.usw2 = aws.usw2
  }

  account_name           = var.account_name
  security_contact_name  = var.security_contact_name
  security_contact_email = var.security_contact_email
  security_contact_phone = data.aws_ssm_parameter.security_contact_phone.value
  security_contact_title = var.security_contact_title

  # Inspector deferred to D-1.
  inspector_enabled = false
}
```

### Component 12 — Module `README.md`

Sections required by Requirement 11:

1. Purpose — links to the parent strategy spec.
2. Inputs — generated table.
3. Outputs — generated table.
4. Usage — example leaf snippet.
5. Verification — the four AWS CLI commands plus the Security Hub re-aggregation step.
6. Rollback — per-control rollback commands.
7. Adding a new account — five-step procedure (copy leaf, change `account_name` and `account_id_ssm_path`, update `backend.tf` `key`, `terraform init`, `apply`).
8. Adding a new region — two-step procedure (extend `configuration_aliases`, extend resource blocks).

## Data Models

### Provider alias map

```
alias    region       AWS partition product
─────    ──────────   ─────────────────────
aws      us-east-2    default provider (home region) — used for account-level
aws.use1 us-east-1    regional provider
aws.use2 us-east-2    regional provider (same physical region as default)
aws.usw2 us-west-2    regional provider
```

The `aws.use2` alias and the unaliased default provider both point at `us-east-2`. Terraform tolerates this because they are distinct providers from the configuration's perspective — the default provider is what unaliased resources use, and `aws.use2` is what region-scoped module resources use.

### SSM Parameter Store paths consumed

| Path | Type | Consumer | Purpose |
|---|---|---|---|
| `/accelerator/organization/account-ids/PCI` | String (LZA-published) | leaf `aws.tooling` provider | Resolve PCI account ID without committing it to code |
| `/security-baseline/security-contact-phone` | SecureString (created by ops) | leaf `aws.tooling` provider | Provide the SECURITY alternate contact phone without committing it to code |

### SSM Parameter Store paths produced

None. The module does not publish to `/accelerator/*` (the deny boundary in `terraform-execution-policy.json` would block it) and it does not publish to any other SSM path. Outputs are surfaced through Terraform `outputs`, not SSM.

### KMS key naming

Alias `alias/security-baseline-ssm-automation-logs` per region. Description encodes purpose. Tags include `Module = security-baseline` for inventory queries.

### State layout

| Leaf | State key |
|---|---|
| Wave 1 | `live/pci/security-baseline/terraform.tfstate` |
| Wave 2 (later) | `live/<account>/security-baseline/terraform.tfstate` per spoke |

Each leaf has its own state file, in line with the project's "one state per leaf" rule. Wave 2 application means new leaves, never co-mingled state.

## Correctness Properties

### Property 1: Module is provider-agnostic at the source level

The module's `*.tf` files contain no `provider` blocks. Providers are supplied by consuming leaves via `configuration_aliases` and the `providers` argument.

**Validates: Requirements 1.6, 2.1, 2.2**

### Property 2: Region settings are statically expressed per provider alias

Per-region resources are written as one explicit block per alias, never via `for_each` over a region set. This enforces that a `terraform plan` shows exactly which region each resource targets.

**Validates: Requirements 2.3, 2.5**

### Property 3: Account settings are applied exactly once per account

Resources targeting account-level configuration (the `aws_account_alternate_contact` and the IAM role) are not provider-aliased and run on the default provider. Re-applying the leaf does not produce duplicate resources.

**Validates: Requirements 6.4, 6.6**

### Property 4: Inspector resources are absent unless enabled

When `inspector_enabled = false` (the default), the three `aws_inspector2_enabler` blocks have `count = 0` and produce no plan diff.

**Validates: Requirements 7.1, 7.5**

### Property 5: Inspector inputs are validated together

When `inspector_enabled = true`, both `inspector_resource_types` and `inspector_regions` must be non-empty. Empty inputs cause `terraform plan` to fail before reaching AWS.

**Validates: Requirements 7.6**

### Property 6: Idempotent apply

After a successful `terraform apply`, a subsequent `terraform plan` reports no changes for the same input variables.

**Validates: Requirements 3.4, 4.5, 5.5, 6.6**

### Property 7: No secret values in outputs or logs

The module does not declare outputs for `security_contact_phone` or `security_contact_email`. The module's `security_contact_phone` variable is declared `sensitive = true`, redacting it from `terraform plan` output. The leaf reads the value from SSM SecureString in SharedServices via the `aws.tooling` provider; the literal phone number never appears in source.

**Validates: Requirements 6.4, 6.6, 6.8, 13.1, 13.2**

### Property 8: No wildcard IAM resource references

The IAM permissions policy attached to the SSM Automation role enumerates the three regional log group ARNs explicitly. No `Resource: "*"` statements.

**Validates: Requirements 13.3**

### Property 9: Module is reusable across accounts without source edits

Adding a new In_Scope_Account requires only a new leaf with different `account_name` and contact-variable values. No edits to any file under `terraform/modules/security-baseline/`.

**Validates: Requirements 9.1, 9.3**

### Property 10: Terraform never operates in Management

The module does not declare any provider that targets the Management account. The leaf assumes only `TerraformExecution` in the spoke account.

**Validates: Requirements 10.1, 13.4, 13.5**

## Error Handling

### LZA has not published `/accelerator/organization/account-ids/PCI`

If the SSM lookup fails because the parameter does not exist, the leaf cannot resolve the spoke account ID. Mitigation: the leaf supports an explicit `var.account_id` override (mirroring the template). Documentation in the leaf README describes how to supply the account ID directly until LZA publishes the parameter.

### `aws_account_alternate_contact` already set with different values

The provider's `update` semantics replace the existing values on `apply`. This is desirable: the module is the source of truth for the SECURITY contact. If a manual change needs to stick, it must be made in the leaf's variable values, not in the Console.

### `aws_ssm_service_setting` does not delete on destroy

This is by design. The setting reverts to its default value (`Enable` for public sharing, no log group for automation) only if explicitly set. Destroying the resource leaves the setting at its last value (`Disable`, or the log group name). This matches the desired security posture.

### KMS key deletion window

The CMKs use the variable's default of 30 days. If the module is destroyed accidentally, the keys enter a pending-deletion state for 30 days, during which they can be cancelled. This protects against accidental data loss in the encrypted log groups.

### CloudWatch log group retention conflict

If the log group already exists with a different retention setting (e.g., set previously by a Console operator), `terraform apply` updates it to the module's value. If a different operator depends on the old retention, that conflict surfaces in the plan diff before apply.

### Inspector enable race

If `inspector_enabled = true` is flipped before the GuardDuty/Inspector delegated admin is configured at the Organization level, `aws_inspector2_enabler` apply fails with a clear AWS error. Mitigation: D-1 includes a prerequisite to confirm Inspector delegated admin is set in the Audit account before enabling.

### Provider version drift

The module pins `~> 5.60`. If a leaf is created with a newer major version, the leaf's `terraform init` will fail. Mitigation: the leaf README pins the same version range; CI runs `terraform init` on every leaf so drift surfaces immediately.

### State lock contention

Two operators running `apply` on the same leaf simultaneously is blocked by the DynamoDB lock table (`lza-terraform-locks`). Standard project behavior; no module-specific mitigation needed.

### Cross-account SCP block

If a future SCP attached to `Workloads/PCI` blocks any of the API calls this module makes (`ssm:UpdateServiceSetting`, `ec2:EnableSnapshotBlockPublicAccess`, `account:PutAlternateContact`, `kms:CreateKey`, `logs:*`, `iam:CreateRole`), the apply fails. Mitigation: the SCPs in `aws-accelerator-config/service-control-policies/` already permit these actions; future SCP changes that would affect this module must be reviewed alongside the module.

## Testing Strategy

### Pre-merge validation

Every PR touching `terraform/modules/security-baseline/` or `terraform/live/pci/security-baseline/` runs in CI:

```
terraform fmt -check -recursive terraform/modules/security-baseline
terraform fmt -check -recursive terraform/live/pci/security-baseline
terraform -chdir=terraform/live/pci/security-baseline init -backend=false
terraform -chdir=terraform/live/pci/security-baseline validate
tflint --chdir terraform/live/pci/security-baseline
```

The `init -backend=false` skips state setup so the validation can run without S3 access. `validate` exercises the module's variable validation rules and provider passing.

### Plan dry-run

CI on PRs additionally runs:

```
aws-actions/configure-aws-credentials@v4   (assumes GitHubActions-Terraform)
terraform -chdir=terraform/live/pci/security-baseline init
terraform -chdir=terraform/live/pci/security-baseline plan -no-color -out tfplan
```

The plan output is posted as a PR comment. Reviewers verify:

- Three `aws_ssm_service_setting` resources for SSM.7 (one per region).
- Three `aws_ebs_snapshot_block_public_access` resources.
- Three CMK + alias + log group + service setting groups.
- One IAM role + role policy.
- One `aws_account_alternate_contact`.
- Zero `aws_inspector2_enabler` (Inspector still disabled).

### Apply on merge

After merge to `main`, CI applies (gated by GitHub environment approval):

```
terraform -chdir=terraform/live/pci/security-baseline apply -auto-approve tfplan
```

The plan from the PR is the same plan applied on merge.

### Post-apply verification

The module README documents (and CI optionally runs) these checks immediately after apply:

```bash
# SSM.7 — public sharing disabled, all 3 regions
for r in us-east-1 us-east-2 us-west-2; do
  aws ssm get-service-setting \
    --setting-id "arn:aws:ssm:$r:<account>:servicesetting/ssm/documents/console/public-sharing-permission" \
    --region "$r" --query 'ServiceSetting.SettingValue'
done
# Expected: "Disable" three times.

# EC2.182 — EBS snapshot block public access
for r in us-east-1 us-east-2 us-west-2; do
  aws ec2 get-snapshot-block-public-access-state --region "$r" --query 'State'
done
# Expected: "block-all-sharing" three times.

# SSM.6 — automation log group setting
for r in us-east-1 us-east-2 us-west-2; do
  aws ssm get-service-setting \
    --setting-id "arn:aws:ssm:$r:<account>:servicesetting/ssm/automation/cloudwatch-log-group" \
    --region "$r" --query 'ServiceSetting.SettingValue'
done
# Expected: "/aws/ssm/automation" three times.

# Account.1 — security contact set
aws account get-alternate-contact --alternate-contact-type SECURITY \
  --query '{Name:Name, Email:EmailAddress, Title:Title}'
# Expected: Alex Gonzalez / security@nebulariscloud.com / CEO. Phone redacted in this query intentionally.
```

### Security Hub re-aggregation

After the AWS CLI checks pass, wait one Security Hub aggregation cycle (~6 hours, sometimes faster) and verify in the delegated admin (Audit) account:

1. Filter findings by `ProductFields.StandardsArn` for FSBP, NIST 800-53 r5, and PCI DSS v4.0.1.
2. Filter by AwsAccountId = PCI account ID.
3. Confirm `SSM.7`, `EC2.182`, `SSM.6`, and `Account.1` are in `PASSED` state.
4. Export findings filtered by these four control IDs and the PCI account; save to the evidence store.

### Idempotency check

Re-run `terraform plan` after a successful `apply`. Expected: `No changes. Your infrastructure matches the configuration.`

If the plan shows changes for the SSM service settings: this can happen on the very first re-run because `aws_ssm_service_setting` reads the setting back differently than it writes. Acceptable behavior is one drift-on-first-read, then stable. If drift persists beyond the second run, raise it as a bug against the module.

### Rollback test (one-time, in a dev account)

Before applying to PCI, roll the module out and back in `Development` to confirm the rollback procedure works:

```bash
# Apply in Development.
terraform -chdir=terraform/live/development/security-baseline apply

# Capture state.
terraform -chdir=terraform/live/development/security-baseline state list > before.txt

# Rollback.
terraform -chdir=terraform/live/development/security-baseline destroy

# Verify revert via the same AWS CLI checks; expect the SSM service settings to remain at the
# safe default (because aws_ssm_service_setting does not revert on destroy — this is the
# desired behavior, see Error Handling).
```

### Wave 2 dry-run

Before applying to additional spokes in Wave 2, run `terraform plan` against a copy of the leaf scaffolded for that spoke. Expected diff: the same six resource families as Wave 1, but with the spoke's account ID resolved from SSM and the spoke's tag values applied.
