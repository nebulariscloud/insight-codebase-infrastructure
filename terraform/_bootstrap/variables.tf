variable "region" {
  description = "Home region. Must match LZA HomeRegion."
  type        = string
  default     = "us-east-2"
}

variable "github_repos" {
  description = <<-EOT
    GitHub repos allowed to assume the GitHubActions-Terraform role via OIDC.
    Format: "owner/repo". Each entry pins to refs/heads/main + tags + environments.
    Wildcards are intentionally not supported here.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.github_repos) > 0
    error_message = "At least one GitHub repo must be provided."
  }
}

variable "tags" {
  description = "Tags applied to every resource created by the bootstrap."
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Stack     = "_bootstrap"
    Purpose   = "lza-terraform-tooling"
  }
}
