###############################################################################
# Dedicated instance role for the Moodle server.
#
# Why not reuse LZA's EC2-Default-SSM-Role:
#   - It's shared by every EC2 in this account. Any custom grant added to
#     it leaks to unrelated workloads.
#   - It's tagged Accelerator=AWSAccelerator. lza-core-guardrails-2 SCP
#     uses that tag to deny iam:PutRolePolicy / iam:AttachRolePolicy from
#     non-LZA principals, so Terraform literally cannot mutate it.
#   - We've seen the bare default role behave inconsistently in practice
#     (apply errors on "InvalidParameterValue: ... Invalid IAM Instance
#     Profile name" and Session Manager intermittently failing on KMS).
#     A Terraform-managed role with explicit AWS-managed policies is the
#     predictable path.
#
# This role mirrors the SSM + CloudWatch Agent permissions LZA grants the
# default role, plus the Session Manager KMS grant (covered automatically
# only when a role is on LZA's `sessionManager.attachPolicyToIamRoles`
# list, which this role isn't). Same structure as sftp-server's iam.tf;
# differs only in that Moodle has no S3 bucket grants.
###############################################################################

# LZA's `sessionManager.sendToCloudWatchLogs = true` (global-config.yaml)
# turns on KMS-encrypted Session Manager streaming. The CMK is created by
# LZA per account/region with the alias below. Without kms:Decrypt +
# kms:GenerateDataKey on this CMK, `aws ssm start-session` fails with:
#   "AccessDeniedException: User ... is not authorized to perform:
#    kms:Decrypt on resource: arn:aws:kms:...:key/...".
data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

data "aws_iam_policy_document" "moodle_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "moodle" {
  name               = "${var.name}-instance-role"
  description        = "Instance role for Moodle. SSM + CloudWatch Agent + Session Manager KMS, no S3 grants."
  assume_role_policy = data.aws_iam_policy_document.moodle_assume.json
}

# Mirror the AWS-managed policies LZA puts on EC2-Default-SSM-Role so SSM
# Session Manager and the CloudWatch Agent keep working unchanged.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.moodle.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.moodle.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Session Manager KMS permissions (see comment on data.aws_kms_alias above).
data "aws_iam_policy_document" "session_manager_kms" {
  statement {
    sid       = "SessionManagerLogsKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.session_manager_logs.target_key_arn]
  }
}

resource "aws_iam_role_policy" "session_manager_kms" {
  name   = "session-manager-kms"
  role   = aws_iam_role.moodle.name
  policy = data.aws_iam_policy_document.session_manager_kms.json
}

resource "aws_iam_instance_profile" "moodle" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.moodle.name
}

output "instance_role_name" {
  description = "Name of the instance role attached to the Moodle server."
  value       = aws_iam_role.moodle.name
}

output "instance_role_arn" {
  description = "ARN of the instance role attached to the Moodle server."
  value       = aws_iam_role.moodle.arn
}
