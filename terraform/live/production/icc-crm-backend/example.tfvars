###############################################################################
# Example values for the icc-crm-backend leaf. Copy to terraform.tfvars and
# adjust. All values here are safe to commit (no secrets).
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
  "https://your-frontend.example.amplifyapp.com",
]

user_pool_name  = "icc-users"
app_client_name = "icc-web"
