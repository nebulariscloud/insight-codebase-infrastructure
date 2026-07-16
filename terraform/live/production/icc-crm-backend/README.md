# icc-crm-backend (Production / shared-prod)

The data plane for the ICC CRM application, ported from a vendor-supplied
CloudShell script into Terraform so it lives in state and ships through the
pipeline like everything else.

Account `395516496764` is our **Production spoke** — not a separate client
account — so this belongs in the normal Terraform flow, not a hand-run script.

## What this leaf owns

| Resource | Detail |
|---|---|
| DynamoDB `icc-crm`, `icc-crm-dev` | Single-table design: PK/SK + GSI1..GSI5 (ProjectionType ALL), PAY_PER_REQUEST, PITR on |
| DynamoDB `icc-crm-audit`, `icc-crm-audit-dev` | PK/SK + GSI1 (ALL), PAY_PER_REQUEST, PITR on |
| S3 `insight-icc-documents`, `insight-icc-documents-dev` | Private (full public-access-block), SSE-S3, versioned, TLS-only, CORS for the frontend origins |
| Cognito user pool `icc-users` + client `icc-web` | Email auto-verify, MFA off, case-insensitive usernames; public SPA client (no secret), 60-min access/id tokens, 5-day refresh |

The **IAM data-access policy** the app's EC2 box uses (DynamoDB + S3 + Cognito)
is NOT here — it lives on the instance role in the
[`insight-ubuntu-dev`](../insight-ubuntu-dev/iam.tf) leaf, which owns that
role. See `icc_data_access` there.

## Deviations from the vendor script (deliberate)

- **Versioning + TLS-only bucket policy** added to both buckets (script omitted them).
- **PITR** enabled on all four tables (cheap safety; script omitted it).
- **`prevent_destroy`** on the user pool so a config drift can never replace it
  and wipe imported users.

## Permissions prerequisite

Creating DynamoDB tables and the Cognito pool requires `TerraformExecution` to
carry `dynamodb:*` and `cognito-idp:*` — neither is in the LZA allow-policy
today. The durable fix is a companion PR adding both to
`aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json`
(runs through the LZA pipeline). Until that propagates, a temporary policy
attached to the `TerraformExecution` role in this account unblocks the apply.
Once the durable allow-policy is live, remove the temporary policy — effective
perms are identical, so that final accelerator run is a no-op on the role.

## After apply — hand these back to the ICC team

From the leaf outputs:

- `user_pool_id`, `app_client_id`
- `document_bucket_names`
- CRM/audit table names (fixed: `icc-crm`, `icc-crm-dev`, `icc-crm-audit`, `icc-crm-audit-dev`)

## See also

- `insight-ubuntu-dev/iam.tf` — the `icc_data_access` grant on the app's instance role
- `claro-recordings/` — the private-bucket pattern this leaf's S3 follows
