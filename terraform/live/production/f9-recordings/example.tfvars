###############################################################################
# Copy to terraform.tfvars and edit before running.
#
# bucket_name defaults to "f9-recordings-prod-<account_id>", which is
# globally unique per Production account. Override only if you've already
# reserved a different name.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "f9-recordings"
region       = "us-east-2"

# Optional override. Leave commented to use the default
# "f9-recordings-prod-<account_id>".
# bucket_name = "f9-recordings-prod-custom"

# Default retention off. Producers apply per-object retention at PutObject
# time. Flip this to true if every uploaded object should be locked
# automatically.
enable_default_object_lock_retention = false
# default_object_lock_mode = "GOVERNANCE"
# default_object_lock_days = 365

# Keep overwritten versions for a year, then expire.
noncurrent_version_retention_days = 365
