###############################################################################
# icc-crm-backend (Production / shared-prod, us-east-2).
#
# The ICC CRM app's data plane: DynamoDB (CRM + audit, prod + dev), private S3
# document buckets (prod + dev), and a Cognito user pool + web client. Ported
# from the vendor's CloudShell script so it's Terraform-managed, in state, and
# goes through the pipeline like everything else.
#
# NOTE: DynamoDB + Cognito creation requires the TerraformExecution role to
# have dynamodb + cognito-idp permissions. Those are being added durably to
# the LZA allow-policy (see the companion PR); until that propagates, a
# temporary policy on the role in this account unblocks the apply.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "icc-crm-backend"
region       = "us-east-2"

crm_table_names   = ["icc-crm", "icc-crm-dev"]
audit_table_names = ["icc-crm-audit", "icc-crm-audit-dev"]

document_bucket_names = ["insight-icc-documents", "insight-icc-documents-dev"]

cors_allowed_origins = [
  "http://localhost:3000",
  "https://update-ventas-productos.d30759srcd7j8q.amplifyapp.com",
]

user_pool_name  = "icc-users"
app_client_name = "icc-web"
