###############################################################################
# WS Aheeva — Wave 2. Fill ami_id + subnet_id + ftps_client_cidrs before apply.
# The FINAL AMI is taken at cutover (mutable disk) — see README.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "ws-aheeva"
region       = "us-east-2"

name = "ws-aheeva"

# Matches the source. NOTE: this is a WINDOWS box (confirmed 2026-08-07 —
# Platform: windows, PlatformDetails: Windows, so License Included), and a License
# Included Windows instance costs meaningfully more per hour than the same size on
# Linux. 4 GB is also tight for Windows Server plus the FTPS service and the loader
# app, but it is what the source runs, so match it and revisit if it struggles.
instance_type = "t3a.medium"

# Rehearsal image, built 2026-08-11 via the two-step copy-image chain:
#   create-image i-025bede8c30dbcece --no-reboot  -> ami-000e85490d76316d9  (aws/ebs key)
#   copy-image same-region, re-encrypted onto transfer CMK e861c20e-...
#                                                -> shared to Production
#   copy-image us-east-1 -> us-east-2, re-encrypted onto the LZA EBS key
#                                                -> this AMI
#
# Verified on the final image: State available, ProductCodes none,
# PlatformDetails "Windows" (survived both re-encryptions — this is the thing that
# silently breaks on the register-image path), Usage operation RunInstances:0002
# which is the Windows License Included billing code, x86_64, hvm, /dev/sda1,
# single volume.
#
# The AMI's own block device mapping says gp2 and DeleteOnTermination=false. Both
# are overridden at launch by the ec2-migrated module, which sets volume_type from
# root_volume_type below, delete_on_termination = true, and re-encrypts with the
# LZA EBS key. Nothing to do about them here.
#
# ⚠️ This is the REHEARSAL image. The disk is mutable — clients drop files daily —
# so it is a point-in-time copy for standing the box up and proving the FTPS path.
# At cutover the file delta is moved separately rather than re-running this chain,
# because the cross-account and cross-region copies are full, not incremental.
# See docs/07-Operations/ws-aheeva-migration-plan.md.
ami_id = "ami-0afa2a16db667ea10"

# A key pair does nothing on its own for a lift-and-shift Windows image — the AMI is
# not Sysprepped, so no Administrator password is generated to decrypt, and the
# EXISTING Windows credentials inside the image are the way in.
#
# It is attached anyway, because it is the prerequisite for the recovery path.
# `AWSSupport-ResetAccess` works on an instance that is NOT SSM-managed (it stops
# the box, attaches the root volume to its own helper, and has EC2Rescue enable
# password generation) — but the password it generates is decrypted with **the key
# pair assigned to the instance**. No key pair, nothing to decrypt it with, no
# recovery path.
#
# Attaching it forces an instance replacement, which is why it is being done NOW,
# while the box is a throwaway rehearsal holding nothing of value. After the FTPS
# configuration work, the same change would be genuinely expensive.
key_name = "ws-aheeva-admin"

# ⚠️ Held at false NOT by choice — the revert to true is blocked by a missing IAM
# action, and leaving it declared true made every apply of this leaf fail.
#
# Background: PR #74 set this false to test whether an SSM agent too old to fetch an
# IMDSv2 token was why the box would not register. That test came back NEGATIVE — the
# replacement instance came up with http_tokens = optional, 2/2 status checks, a clean
# Windows lock screen, the correct instance profile, in a subnet where SSM demonstrably
# works, and still did not register. The agent is simply absent, and the user_data that
# would have installed it never ran (EC2Launch skips user data on an image that was
# never Sysprepped).
#
# So PR #75 set it back to true — and the apply failed:
#
#   UnauthorizedOperation: ... assumed-role/TerraformExecution/tf-Production-ws-aheeva
#   is not authorized to perform: ec2:ModifyInstanceMetadataOptions ... because no
#   identity-based policy allows the ec2:ModifyInstanceMetadataOptions action
#
# "no identity-based policy allows" = a gap in the TerraformExecution allow-policy,
# which is an explicit allow-list. Not an SCP deny. Leaving the leaf declaring `true`
# would have meant a permanently red apply on every future change to this leaf, which
# masks real failures — so it is parked at false deliberately.
#
# HOW IT GETS BACK TO TRUE — either path, no ModifyInstanceMetadataOptions needed:
#
#   1. On the next instance replacement (which is coming anyway, with the AMI rebuilt
#      after the SSM agent is installed on the source box — see
#      docs/07-Operations/ws-aheeva-migration-plan.md Phase 2a). Metadata options are
#      settable at LAUNCH via RunInstances, which IS in the allow-policy. Proof: the
#      original instance was created with http_tokens = required and that apply
#      succeeded. **Flip this to true in the same PR that updates ami_id.**
#
#   2. Or once the allow-policy gains ec2:ModifyInstanceMetadataOptions via the next
#      LZA pipeline run — the edit is already staged in
#      aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json.
#
# Until then: IMDSv1 is reachable on this box. Mitigated by it being private, having no
# public IP, and holding nothing — but it is a known open item, not a settled state.
imdsv2_required = false

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a

# Pin an unused app-a IP so the FTPS NLB target stays stable.
private_ip = "10.12.1.66"

root_volume_size_gib = 80

# FTPS: implicit-TLS control 990 + passive range, from the ingress NLB.
#
# The source allowed 40000-40500 (501 ports). That is kept NARROWED to 20 here
# to match the NLB leaf, which needs one listener + one target group per port and
# would blow through the default listener quota at 501. These three values must
# stay in lockstep across three places:
#   1. this SG range
#   2. terraform/live/perimeter/ws-aheeva-ftps-nlb/terraform.tfvars
#   3. the FTPS server's own pasv_min_port/pasv_max_port inside the box
# A mismatch fails in the ugliest way: control connection succeeds, directory
# listing hangs, and the client reports a vague timeout.
ftps_control_port = 990
ftps_passive_from = 40000
ftps_passive_to   = 40019
ingress_vpc_cidr  = "10.0.0.0/20"

# ⚠️ TEMPORARY SCAFFOLDING — remove once this box has a working SSM agent.
#
# 10.12.1.16 is cti-v7-ddhelper, which IS SSM-managed and sits in this same subnet.
# This box is not, so the only route in is RDP tunnelled through that bastion with
# AWS-StartPortForwardingSessionToRemoteHost. Nothing is published to the internet:
# the source is a private /32 and the tunnel rides ddhelper's outbound SSM channel.
#
# ddhelper is on the cleanup list (open-items E2) precisely because it is the last
# SSM path into this subnet — do not delete it while this is in use.
admin_rdp_cidrs = ["10.12.1.16/32"]

# Extra ports beyond FTPS. Read from the source SG sg-0236c297e78a62ab2 on
# 2026-08-07 and deliberately NOT copied wholesale — see README "Source security
# group" for the full inventory and the reasoning.
#
# 8081 is the one that is not optional. The source allows it from 10.0.100.0/24
# described "Aheeva-srv-wsIF" — that subnet is CTI v7's (it sits at 10.0.100.227
# there). So CTI v7 calls WS Aheeva's web-service interface on 8081, and without an
# equivalent rule the cluster is broken in a way FTPS testing will not reveal.
# In the new tenant CTI v7 is 10.12.0.42.
#
# ⚠️ CONFIRM before cutover: that 8081 is the only port CTI v7 needs. The source
# also has a blanket all-traffic rule that includes CTI v7's subnet and its old
# public IP (54.152.253.96), so 8081 is an inference from the one *specific* rule,
# not a complete picture. If CTI v7 uses other ports they are currently hidden
# inside that all-traffic rule.
extra_app_ports = [8081]
extra_app_cidrs = ["10.12.0.42/32"] # CTI v7 in shared-prod

# NOT reproduced from the source, on purpose:
#   8025  -> open to 0.0.0.0/0 there, purpose unknown. Not carrying that over.
#   8081  -> ALSO open to 0.0.0.0/0 there, on top of the CTI v7 rule above.
#            Scoped to CTI v7 only here.
#   8078  -> single IP labelled "GQA test" (34.239.135.131). Looks like a test
#            fixture; confirm it is live before adding.
#   3389  -> RDP from five admin /32s. Access should be SSM, not RDP from the
#            internet. If this really is a Windows box and RDP is unavoidable,
#            route it through SSM port forwarding rather than an ingress rule.
#   22    -> SSH from Five9 ("F9") Santa Clara and Atlanta ranges, ~8 CIDRs
#            including a /19. Third-party vendor access. Needs an owner and a
#            justification before it is recreated.
#   all traffic from 16 sources -> the legacy sprawl rule. Same exercise the DB's
#            18-IP list went through: every entry needs an owner, a port and a
#            yes/no. Includes Aheeva V8/dev boxes, InConcert, ALF, gqa_otva, QNAP,
#            and two named individuals.

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
