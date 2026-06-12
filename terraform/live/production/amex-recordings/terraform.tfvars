account_name = "Production"
account_id   = "395516496764"
stack_name   = "amex-recordings"
region       = "us-east-2"

# Bucket name defaults to "amex-recordings-prod-<account_id>", which is
# globally unique. Uncomment to override.
# bucket_name = "amex-recordings-prod-custom"

# Default retention off. Producers attach Object Lock retention per-object
# at PutObject time. Flip to true if every object should be locked on upload.
enable_default_object_lock_retention = false
# default_object_lock_mode = "GOVERNANCE"
# default_object_lock_days = 365

# Keep overwritten versions for a year, then expire.
noncurrent_version_retention_days = 365
