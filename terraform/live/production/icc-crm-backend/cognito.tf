###############################################################################
# Cognito — ICC user pool + web app client
#
# Ports the vendor's create-user-pool / create-user-pool-client calls. Users
# are imported separately (not Terraform-managed). Email auto-verify, MFA off,
# case-insensitive usernames, standard password policy. The app client is a
# public SPA client (no secret) with the SRP/password/refresh auth flows.
###############################################################################

resource "aws_cognito_user_pool" "icc" {
  name = var.user_pool_name

  username_configuration {
    case_sensitive = false
  }

  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  # The pool holds imported users; don't let an accidental config drift
  # trigger a replacement (which would delete every user).
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Role = "icc-users"
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = var.app_client_name
  user_pool_id = aws_cognito_user_pool.icc.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  prevent_user_existence_errors = "ENABLED"
}

output "user_pool_id" {
  description = "Cognito user pool ID. Send to the ICC team."
  value       = aws_cognito_user_pool.icc.id
}

output "user_pool_arn" {
  description = "Cognito user pool ARN (for the instance-role Cognito grant)."
  value       = aws_cognito_user_pool.icc.arn
}

output "app_client_id" {
  description = "Cognito app client ID. Send to the ICC team."
  value       = aws_cognito_user_pool_client.web.id
}
