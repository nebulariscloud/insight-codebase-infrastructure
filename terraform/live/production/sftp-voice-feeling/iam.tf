###############################################################################
# Dedicated instance role for the SFTP VOFeeling server.
#
# Why not reuse LZA's EC2-Default-SSM-Role:
#   - It's tagged Accelerator=AWSAccelerator, which the lza-core-guardrails-2
#     SCP uses to deny iam:PutRolePolicy / iam:AttachRolePolicy from non-LZA
#     principals. Terraform literally cannot mutate it.
#   - A dedicated role keeps this workload's permissions self-contained.
#
# This role mirrors the SSM + CloudWatch Agent permissions LZA grants the
# default role, plus the Session Manager KMS grant. The role name and absence
# of an Accelerator tag keep it inside the TerraformExecution allow-list
# (NotResource: AWSAccelerator-*).
#
# NOTE: unlike terraform/live/production/sftp-server/, this leaf has NO amex
# recordings S3/KMS grant. If this box ever needs to write to an S3 bucket,
# add a scoped inline policy here (copy the amex_bucket pattern from that leaf).
###############################################################################

# LZA's `sessionManager.sendToCloudWatchLogs = true` (global-config.yaml)
# turns on KMS-encrypted Session Manager streaming. Without kms:Decrypt +
# kms:GenerateDataKey on this CMK, `aws ssm start-session` fails with an
# AccessDeniedException on kms:Decrypt. LZA wires this onto its own
# EC2-Default-SSM-Role via sessionManager.attachPolicyToIamRoles; our
# dedicated role isn't on that list, so we grant it directly here.
data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

data "aws_iam_policy_document" "sftp_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sftp" {
  name               = "${var.name}-instance-role"
  description        = "Instance role for the SFTP VOFeeling server. SSM + CloudWatch Agent + Session Manager KMS."
  assume_role_policy = data.aws_iam_policy_document.sftp_assume.json
}

# Mirror the AWS-managed policies LZA puts on EC2-Default-SSM-Role so SSM
# Session Manager and the CloudWatch Agent keep working unchanged.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.sftp.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.sftp.name
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
  role   = aws_iam_role.sftp.name
  policy = data.aws_iam_policy_document.session_manager_kms.json
}

resource "aws_iam_instance_profile" "sftp" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.sftp.name
}

output "instance_role_name" {
  description = "Name of the instance role attached to the SFTP server."
  value       = aws_iam_role.sftp.name
}

output "instance_role_arn" {
  description = "ARN of the instance role attached to the SFTP server."
  value       = aws_iam_role.sftp.arn
}
