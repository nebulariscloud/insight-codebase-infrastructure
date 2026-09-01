# Offline SSM-agent bootstrap for WS Aheeva.
#
# Runs on the EC2Rescue HELPER instance, with the target's root volume mounted
# offline, via AWSSupport-StartEC2RescueWorkflow (OfflineScript parameter).
#
# WHY THIS EXISTS
#   i-00489e263e7eaf005 has no SSM agent, and on Windows there is no SSH
#   fallback and no generated Administrator password (the AMI was never
#   Sysprepped), so there is no way in. AWSSupport-ResetAccess cannot help
#   because it refuses encrypted root volumes and LZA mandates EBS encryption.
#   Calling the nested workflow directly with AllowEncryptedVolume=True is the
#   remaining route.
#
# WHAT IT DOES
#   Installs a Local Group Policy *startup script* on the offline disk. Windows
#   runs machine startup scripts at boot as SYSTEM, before any logon, which is
#   exactly what we need. The script then installs the SSM agent from the
#   internet (the box has NAT egress) and starts it.
#
# WHY THIS APPROACH
#   It is ADDITIVE ONLY. It creates four files and modifies nothing that already
#   exists — no registry hive loading, no service registration, no edits to
#   LaunchConfig.json or EC2Launch state. If it does not work, nothing is broken
#   and the box boots exactly as it does today. The alternatives all involve
#   mounting and editing the offline SYSTEM registry hive, which can corrupt an
#   image.
#
#   Trade-off accepted: Group Policy startup scripts only fire if the Group
#   Policy client processes them, which requires gpt.ini to advertise the Scripts
#   client-side extension GUIDs. That is what gPCMachineExtensionNames below is
#   for. If the box already had local GPO settings this would need merging rather
#   than overwriting — checked for below, and the script refuses rather than
#   clobbering.

$ErrorActionPreference = 'Stop'

function Log($m) { Write-Output ("[offline-ssm] " + $m) }

$sysRoot = $env:EC2RESCUE_OFFLINE_SYSTEM_ROOT     # e.g. D:\Windows
if (-not $sysRoot) { throw "EC2RESCUE_OFFLINE_SYSTEM_ROOT is not set - not running inside the EC2Rescue workflow?" }
Log "offline system root: $sysRoot"

$gpDir      = Join-Path $sysRoot 'System32\GroupPolicy'
$scriptsDir = Join-Path $gpDir   'Machine\Scripts'
$startupDir = Join-Path $scriptsDir 'Startup'
$gptIniPath = Join-Path $gpDir 'gpt.ini'

# Refuse to clobber an existing local GPO rather than silently merging badly.
if (Test-Path $gptIniPath) {
  $existing = Get-Content $gptIniPath -Raw
  if ($existing -notmatch 'gPCMachineExtensionNames') {
    Log "WARNING: existing gpt.ini has no machine extensions - will append ours"
  } else {
    Log "ERROR: gpt.ini already declares machine extensions. Refusing to overwrite."
    Log "Existing content:"
    Log $existing
    throw "Existing local Group Policy detected. Merge by hand rather than overwriting."
  }
}

New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
Log "created $startupDir"

# ---------------------------------------------------------------------------
# The payload that runs at boot. Kept in a .ps1 with a tiny .cmd wrapper so we
# do not have to nest quotes inside an INI-referenced command line.
# ---------------------------------------------------------------------------
$payload = @'
$ErrorActionPreference = 'Continue'
$log = 'C:\Windows\Temp\ssm-gpo.log'
function W($m) { "$(Get-Date -Format s)  $m" | Out-File -FilePath $log -Append -Encoding utf8 }

W 'startup script running'

# Old Windows defaults to TLS 1.0, which the S3 endpoint refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { W 'TLS 1.2 could not be set' }

$svc = Get-Service -Name AmazonSSMAgent -ErrorAction SilentlyContinue
if (-not $svc) {
  W 'agent absent - downloading'
  $url = 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe'
  $exe = 'C:\Windows\Temp\AmazonSSMAgentSetup.exe'
  try {
    # Net.WebClient rather than Invoke-WebRequest: the latter is absent on PowerShell 2.0.
    (New-Object Net.WebClient).DownloadFile($url, $exe)
    W 'download ok - installing'
    Start-Process -FilePath $exe -ArgumentList '/quiet','/norestart' -Wait
    W 'install finished'
  } catch {
    W ("install failed: " + $_.Exception.Message)
  }
} else {
  W ("agent present, status " + $svc.Status)
}

try {
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
  Start-Service -Name AmazonSSMAgent -ErrorAction SilentlyContinue
  W ("service status now " + (Get-Service AmazonSSMAgent).Status)
} catch {
  W ("could not start service: " + $_.Exception.Message)
}

W 'startup script done'
'@

$payloadPath = Join-Path $startupDir 'install-ssm.ps1'
Set-Content -Path $payloadPath -Value $payload -Encoding ASCII
Log "wrote $payloadPath"

$wrapper = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ssm.ps1" >> C:\Windows\Temp\ssm-gpo-wrapper.log 2>&1
'@
$wrapperPath = Join-Path $startupDir 'install-ssm.cmd'
Set-Content -Path $wrapperPath -Value $wrapper -Encoding ASCII
Log "wrote $wrapperPath"

# scripts.ini MUST be UTF-16LE ("Unicode") - the Group Policy client will not
# read it otherwise. This is the single most common reason startup scripts are
# silently ignored.
$scriptsIni = @'
[Startup]
0CmdLine=install-ssm.cmd
0Parameters=
'@
$scriptsIniPath = Join-Path $scriptsDir 'scripts.ini'
Set-Content -Path $scriptsIniPath -Value $scriptsIni -Encoding Unicode
Log "wrote $scriptsIniPath (UTF-16LE)"

# The two GUIDs are the Scripts client-side extension and the Group Policy core.
# Without them the Group Policy client never processes scripts.ini.
$gptIni = @'
[General]
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1
'@
Set-Content -Path $gptIniPath -Value $gptIni -Encoding ASCII
Log "wrote $gptIniPath"

Log "done - all four files written, nothing existing was modified"
Get-ChildItem -Recurse $gpDir | Select-Object -ExpandProperty FullName | ForEach-Object { Log "  $_" }
