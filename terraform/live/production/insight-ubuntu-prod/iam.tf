###############################################################################
# Dedicated instance role for insight-ubuntu-prod.
#
# Same rationale as moodle/iam.tf: LZA's EC2-Default-SSM-Role is tagged
# Accelerator=AWSAccelerator so SCPs deny iam:PutRolePolicy from
# Terraform, and Session Manager needs the KMS grant on the LZA-managed
# accelerator/sessionmanager-logs/session CMK. A dedicated,
# Terraform-managed role is the predictable path.
###############################################################################

data "aws_kms_alias" "session_manager_logs" {
  name = "alias/accelerator/sessionmanager-logs/session"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-instance-role"
  description        = "Instance role for ${var.name}. SSM + CloudWatch Agent + Session Manager KMS."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "session_manager_kms" {
  statement {
    sid       = "SessionManagerLogsKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [data.aws_kms_alias.session_manager_logs.target_key_arn]
  }
}

resource "aws_iam_role_policy" "session_manager_kms" {
  name   = "session-manager-kms"
  role   = aws_iam_role.this.name
  policy = data.aws_iam_policy_document.session_manager_kms.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.this.name
}

output "instance_role_arn" {
  description = "ARN of the instance role."
  value       = aws_iam_role.this.arn
}
