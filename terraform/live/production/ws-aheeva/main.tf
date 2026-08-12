###############################################################################
# WS Aheeva (Production / shared-prod) — Wave 2
#
# Lift-and-shift of the WS Aheeva file-loader from the source tenant
# (254422596287 / us-east-1, i-025bede8c30dbcece, 172.30.2.200) into
# shared-prod / us-east-2. This is the box clients drop daily files onto over
# FTPS; it processes them and writes into the RDS (iccmaindb).
#
# Disk is mutable (the file inbox changes), so the FINAL AMI is taken at
# cutover (after draining the inbound queue), not from a stale baseline.
#
# Source root volume is 80 GiB, encrypted with aws/ebs (AWS-managed,
# unshareable) — the AMI is produced via the transfer-CMK re-encrypt dance
# (see README), same as webapps-php73.
#
# Cutover ordering: WS Aheeva cuts over WITH the RDS (Wave 2). After the RDS
# is promoted, WS Aheeva's DB connection string is pointed at the new
# iccmaindb endpoint (config edit inside the box, over SSH/SSM).
###############################################################################

locals {
  # FTPS control + passive range, from the perimeter ingress NLB CIDR (the NLB
  # SNATs, so the box sees NLB private IPs). Client-IP allowlisting is enforced
  # at the NLB SG layer in the sibling perimeter/ws-aheeva-ftps-nlb leaf.
  ftps_rules = [
    {
      from_port   = var.ftps_control_port
      to_port     = var.ftps_control_port
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "FTPS control ${var.ftps_control_port} from ingress NLB"
    },
    {
      from_port   = var.ftps_passive_from
      to_port     = var.ftps_passive_to
      protocol    = "tcp"
      cidr_blocks = [var.ingress_vpc_cidr]
      description = "FTPS passive ${var.ftps_passive_from}-${var.ftps_passive_to} from ingress NLB"
    },
  ]

  # Extra Aheeva app/admin ports, scoped to admin CIDRs (cartesian of ports x cidrs).
  extra_rules = flatten([
    for p in var.extra_app_ports : [
      for c in var.extra_app_cidrs : {
        from_port   = p
        to_port     = p
        protocol    = "tcp"
        cidr_blocks = [c]
        description = "Aheeva app/admin ${p} from ${c}"
      }
    ]
  ])

  ingress_rules   = concat(local.ftps_rules, local.extra_rules)
  ebs_kms_key_arn = var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : data.aws_kms_key.ebs.arn

  #############################################################################
  # SSM agent bootstrap.
  #
  # This box came up healthy — running, 2/2 status checks, correct instance
  # profile, in a subnet where SSM demonstrably works (ddhelper is managed at
  # 10.12.1.16) — and sat there 30+ minutes without ever registering. So the
  # agent is missing, stopped, or too old to fetch an IMDSv2 token.
  #
  # Without SSM there is no way into this box at all: it is Windows, so there is
  # no SSH fallback, and the Administrator password is not in our hands. Session
  # Manager was the one path that did not need it, because it runs as SYSTEM.
  #
  # Opportunistic, NOT a guarantee. On an image that was never Sysprepped,
  # EC2Launch/EC2Config may treat user data as already consumed and skip it.
  # <persist>true</persist> gives it a chance on this and later boots. If it does
  # not run, nothing is lost — the key-pair + AWSSupport-ResetAccess path stands.
  #
  # Written to survive an old box:
  #   - Net.WebClient, because Invoke-WebRequest does not exist on PowerShell 2.0
  #   - TLS 1.2 forced, because older Windows defaults to 1.0 and S3 refuses it
  #   - idempotent: installs only when the service is genuinely absent, so it is
  #     harmless on every subsequent boot
  #   - logs to C:\Windows\Temp\ssm-bootstrap.log, the first thing to read once
  #     we have a shell
  #
  # NOTE: user data is readable from IMDS, and IMDSv1 is temporarily permitted on
  # this instance, so nothing secret may ever go in here. This contains no
  # credentials.
  #############################################################################
  ssm_agent_bootstrap = <<-EOT
    <powershell>
    $ErrorActionPreference = 'Continue'
    $log = 'C:\Windows\Temp\ssm-bootstrap.log'
    function Write-Log($m) { "$(Get-Date -Format s)  $m" | Out-File -FilePath $log -Append -Encoding utf8 }

    Write-Log 'ssm bootstrap starting'

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Log 'could not set TLS 1.2; continuing' }

    $svc = Get-Service -Name AmazonSSMAgent -ErrorAction SilentlyContinue

    if (-not $svc) {
      Write-Log 'AmazonSSMAgent service not present - downloading installer'
      $url = 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe'
      $exe = 'C:\Windows\Temp\AmazonSSMAgentSetup.exe'
      try {
        (New-Object Net.WebClient).DownloadFile($url, $exe)
        Write-Log 'download ok - installing quietly'
        Start-Process -FilePath $exe -ArgumentList '/quiet','/norestart' -Wait
        Write-Log 'installer finished'
      } catch {
        Write-Log "install failed: $($_.Exception.Message)"
      }
    } else {
      Write-Log "AmazonSSMAgent present, status $($svc.Status)"
    }

    try {
      Set-Service -Name AmazonSSMAgent -StartupType Automatic
      Start-Service -Name AmazonSSMAgent -ErrorAction SilentlyContinue
      Write-Log "service set Automatic, status now $((Get-Service AmazonSSMAgent).Status)"
    } catch {
      Write-Log "could not start service: $($_.Exception.Message)"
    }

    Write-Log 'ssm bootstrap done'
    </powershell>
    <persist>true</persist>
  EOT
}

data "aws_kms_key" "ebs" {
  key_id = "alias/accelerator/ebs/default-encryption/key"
}

module "ec2_migrated" {
  source = "../../../modules/ec2-migrated"

  name          = var.name
  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  vpc_id        = var.vpc_id
  private_ip    = var.private_ip
  key_name      = var.key_name

  iam_instance_profile = "EC2-Default-SSM-Role"

  ingress_rules = local.ingress_rules

  root_volume_size       = var.root_volume_size_gib
  root_volume_type       = "gp3"
  root_volume_kms_key_id = local.ebs_kms_key_arn

  user_data               = local.ssm_agent_bootstrap
  imdsv2_required         = var.imdsv2_required
  monitoring              = false # ec2:MonitorInstances not in the TF allow-policy
  ebs_optimized           = true
  disable_api_termination = true

  tags = {
    Role = "ws-aheeva"
  }
}

resource "aws_vpc_security_group_ingress_rule" "eice_ssh" {
  count = var.eice_security_group_id == "" ? 0 : 1

  security_group_id            = module.ec2_migrated.security_group_id
  referenced_security_group_id = var.eice_security_group_id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "Admin SSH from EC2 Instance Connect Endpoint"
}

###############################################################################
# Outputs — the perimeter FTPS NLB leaf reads private_ip and targets it.
###############################################################################

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.ec2_migrated.instance_id
}

output "private_ip" {
  description = "Private IP. Target this from the perimeter FTPS NLB."
  value       = module.ec2_migrated.private_ip
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = module.ec2_migrated.security_group_id
}

output "availability_zone" {
  description = "AZ the instance landed in."
  value       = module.ec2_migrated.availability_zone
}
