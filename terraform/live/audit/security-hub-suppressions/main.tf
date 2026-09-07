###############################################################################
# Security Hub automation rules managed from the Audit account (delegated
# Security Hub administrator for the organization).
#
# Rules here are applied organization-wide thanks to Security Hub's region
# aggregation being enabled in security-config.yaml.
#
# Findings closed by this leaf:
#   - CloudFormation.4 (Medium) — LZA AWSAccelerator-* stacks cannot have a
#     service role associated by design. AWS documentation explicitly states
#     that service-managed StackSets cannot populate the roleARN field.
#     Reference: https://docs.aws.amazon.com/securityhub/latest/userguide/cloudformation-controls.html
###############################################################################

###############################################################################
# CloudFormation.4 — Suppress FAILED findings for AWSAccelerator-* stacks
#
# Why suppress instead of remediate:
#   The CloudFormation service role (roleARN) is immutable once assigned, and
#   LZA stacks are created by the Accelerator pipeline without a service role
#   because service-managed StackSets use Organizations trusted-access
#   authentication — the roleARN field cannot be populated for these stacks.
#   Manually attaching a role to AWSAccelerator-* stacks would break future
#   LZA pipeline runs that re-create or update those stacks.
#
# Scope:
#   - GeneratorId = "security-control/CloudFormation.4" matches this control.
#   - ResourceId CONTAINS "/AWSAccelerator-" targets only LZA-managed stacks
#     (Security Hub stores the full stack ARN as ResourceId, e.g.
#     arn:aws:cloudformation:us-east-1:123456789012:stack/AWSAccelerator-*/uuid).
#   - WorkflowStatus NEW/NOTIFIED ensures we only suppress open findings;
#     already-suppressed ones are left untouched (idempotent).
#
# Audit trail:
#   The Note text is stored on every suppressed finding as the audit record.
###############################################################################

resource "aws_securityhub_automation_rule" "suppress_cloudformation4_lza_stacks" {
  rule_name   = "Suppress-CloudFormation4-LZA-AWSAccelerator-Stacks"
  rule_order  = 1
  rule_status = "ENABLED"
  description = "Suppresses CloudFormation.4 FAILED findings for AWSAccelerator-* stacks. These stacks are managed by Landing Zone Accelerator and cannot have a service role by design (service-managed StackSets do not support roleARN). See AWS Security Hub CloudFormation controls documentation."

  criteria {
    generator_id {
      comparison = "EQUALS"
      value      = "security-control/CloudFormation.4"
    }

    # Security Hub stores the full stack ARN as ResourceId, e.g.:
    # arn:aws:cloudformation:us-east-1:123456789012:stack/AWSAccelerator-Logging/uuid
    # CONTAINS on "/AWSAccelerator-" isolates all LZA-managed stacks across
    # all accounts and regions without over-matching.
    resource_id {
      comparison = "CONTAINS"
      value      = "/AWSAccelerator-"
    }

    workflow_status {
      comparison = "EQUALS"
      value      = "NEW"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"

    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }

      note {
        text       = "Known AWS limitation: LZA AWSAccelerator-* stacks are created by service-managed StackSets which cannot populate roleARN. Remediation is not possible without breaking future LZA pipeline runs. Suppressed per architectural decision — see CloudFormation.4 remediation strategy in insight-codebase-infrastructure."
        updated_by = "terraform-automation-rule"
      }
    }
  }
}

###############################################################################
# Supplemental rule: catch any NOTIFIED findings that slipped through before
# this automation rule was deployed (e.g. findings that were already notified
# but not yet suppressed).
###############################################################################

resource "aws_securityhub_automation_rule" "suppress_cloudformation4_lza_stacks_notified" {
  rule_name   = "Suppress-CloudFormation4-LZA-AWSAccelerator-Stacks-Notified"
  rule_order  = 2
  rule_status = "ENABLED"
  description = "Same as rule order 1 but targets NOTIFIED findings for AWSAccelerator-* stacks that were generated before the suppression rule was in place."

  criteria {
    generator_id {
      comparison = "EQUALS"
      value      = "security-control/CloudFormation.4"
    }

    resource_id {
      comparison = "CONTAINS"
      value      = "/AWSAccelerator-"
    }

    workflow_status {
      comparison = "EQUALS"
      value      = "NOTIFIED"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"

    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }

      note {
        text       = "Known AWS limitation: LZA AWSAccelerator-* stacks are created by service-managed StackSets which cannot populate roleARN. Remediation is not possible without breaking future LZA pipeline runs. Suppressed per architectural decision — see CloudFormation.4 remediation strategy in insight-codebase-infrastructure."
        updated_by = "terraform-automation-rule"
      }
    }
  }
}

###############################################################################
# CloudFormation.4 — Suppress FAILED findings for StackSet-AWSControlTowerBP-* stacks
#
# Why suppress:
#   These stacks are deployed and managed by AWS Control Tower as baseline
#   StackSets (CONFIG, CLOUDWATCH, SERVICE-LINKED-ROLE, SERVICE-ROLES, ROLES).
#   Like LZA stacks, they are service-managed and cannot have a roleARN
#   associated with them. Modifying them would break Control Tower governance.
#
# Inventory (confirmed 2026-09-07, account 247514667218, us-east-2/us-east-1/us-west-2):
#   StackSet-AWSControlTowerBP-BASELINE-CONFIG-*
#   StackSet-AWSControlTowerBP-BASELINE-CLOUDWATCH-*
#   StackSet-AWSControlTowerBP-BASELINE-SERVICE-LINKED-ROLE-*
#   StackSet-AWSControlTowerBP-BASELINE-SERVICE-ROLES-*
#   StackSet-AWSControlTowerBP-BASELINE-ROLES-*
###############################################################################

resource "aws_securityhub_automation_rule" "suppress_cloudformation4_controltower_stacks" {
  rule_name   = "Suppress-CloudFormation4-ControlTower-StackSet-Stacks"
  rule_order  = 3
  rule_status = "ENABLED"
  description = "Suppresses CloudFormation.4 FAILED findings for StackSet-AWSControlTowerBP-* stacks. These are AWS Control Tower baseline StackSets that cannot have a service role by design."

  criteria {
    generator_id {
      comparison = "EQUALS"
      value      = "security-control/CloudFormation.4"
    }

    resource_id {
      comparison = "CONTAINS"
      value      = "/StackSet-AWSControlTowerBP-"
    }

    workflow_status {
      comparison = "EQUALS"
      value      = "NEW"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"

    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }

      note {
        text       = "Known AWS limitation: Control Tower baseline StackSets (AWSControlTowerBP) cannot populate roleARN by design. Remediation is not possible without breaking Control Tower governance. Suppressed per architectural decision — see CloudFormation.4 remediation strategy in insight-codebase-infrastructure."
        updated_by = "terraform-automation-rule"
      }
    }
  }
}

resource "aws_securityhub_automation_rule" "suppress_cloudformation4_controltower_stacks_notified" {
  rule_name   = "Suppress-CloudFormation4-ControlTower-StackSet-Stacks-Notified"
  rule_order  = 4
  rule_status = "ENABLED"
  description = "Same as rule order 3 but targets NOTIFIED findings for StackSet-AWSControlTowerBP-* stacks generated before this rule was deployed."

  criteria {
    generator_id {
      comparison = "EQUALS"
      value      = "security-control/CloudFormation.4"
    }

    resource_id {
      comparison = "CONTAINS"
      value      = "/StackSet-AWSControlTowerBP-"
    }

    workflow_status {
      comparison = "EQUALS"
      value      = "NOTIFIED"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"

    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }

      note {
        text       = "Known AWS limitation: Control Tower baseline StackSets (AWSControlTowerBP) cannot populate roleARN by design. Remediation is not possible without breaking Control Tower governance. Suppressed per architectural decision — see CloudFormation.4 remediation strategy in insight-codebase-infrastructure."
        updated_by = "terraform-automation-rule"
      }
    }
  }
}
