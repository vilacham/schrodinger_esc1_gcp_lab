$domain = "${domain_name}"
$netbios = "${domain_netbios}"
$AdminPlain = "${domain_admin_password}"
$dcIp = "${dc_ip}"
$AdminPass = ConvertTo-SecureString $AdminPlain -AsPlainText -Force

$domCred = New-Object System.Management.Automation.PSCredential ("$netbios\Administrator", $AdminPass)

# Ensure DNS points to DC so the domain can be resolved before join
try {
  $ifs = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' }
  foreach ($if in $ifs) {
    Set-DnsClientServerAddress -InterfaceIndex $if.InterfaceIndex -ServerAddresses $dcIp
    try { Set-DnsClient -InterfaceIndex $if.InterfaceIndex -ConnectionSpecificSuffix $domain -UseSuffixWhenRegistering $true -RegisterThisConnectionsAddress $true } catch {}
  }
  try { Set-DnsClientGlobalSetting -SuffixSearchList @($domain) } catch {}
} catch {}

# Wait for DC promotion to complete (DNS, DS, SYSVOL); timeout ~20 minutes
function Wait-ForDC {
  param([string]$Domain,[string]$DcHost)
  $deadline = (Get-Date).AddMinutes(20)
  do {
    $dnsOk = $false; $dsOk = $false; $sysvolOk = $false
    try { $null = Resolve-DnsName -Name $Domain -ErrorAction Stop; $dnsOk = $true } catch {}
    try { & nltest /dsgetdc:$Domain | Out-Null; if ($LASTEXITCODE -eq 0) { $dsOk = $true } } catch {}
    try { if (Test-Path "\\$DcHost\sysvol") { $sysvolOk = $true } } catch {}
    if ($dnsOk -and $dsOk -and $sysvolOk) { return $true }
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  return $false
}

$null = Wait-ForDC -Domain $domain -DcHost $dcIp

# Use persistent markers
try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
$rdpMarker = "C:\\ProgramData\\LabState\\rdp-enabled.done"
if (-not (Test-Path $rdpMarker)) {
  try {
    Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    New-Item -Path $rdpMarker -ItemType File -Force | Out-Null
  } catch {}
}

$partOfDomain = (Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain
if (-not $partOfDomain) {
  Add-Computer -DomainName $domain -Credential $domCred -Force -Restart
} else {
  try {
    $aliceAcct = "$netbios\alice"
    $bobAcct   = "$netbios\bob"
    net localgroup "Remote Desktop Users" $aliceAcct /add | Out-Null
    net localgroup "Remote Desktop Users" $bobAcct   /add | Out-Null
    # Also add to local Administrators to allow RDP logon in this lab
    net localgroup "Administrators" $aliceAcct /add | Out-Null
    net localgroup "Administrators" $bobAcct   /add | Out-Null
  } catch {}

  # Enable RDP and firewall on this workstation
  try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
  } catch {}

  try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue
    Set-MpPreference -PUAProtection 0 -ErrorAction SilentlyContinue
    $exclusions = @('C:\\Tools','C:\\Users\\Public\\Downloads')
    foreach ($p in $exclusions) { if (-not (Get-MpPreference).ExclusionPath -contains $p) { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue } }
    Stop-Service -Name WinDefend -Force -ErrorAction SilentlyContinue
    Set-Service -Name WinDefend -StartupType Disabled -ErrorAction SilentlyContinue
  } catch {}

  try {
    $taskName = 'DisableDefender'
    schtasks /Query /TN $taskName 2>$null
    if ($LASTEXITCODE -ne 0) {
      $cmd = 'powershell -ExecutionPolicy Bypass -Command "Set-MpPreference -DisableRealtimeMonitoring $true; Set-MpPreference -DisableIOAVProtection $true; Set-MpPreference -DisableBehaviorMonitoring $true; Stop-Service WinDefend -Force -ErrorAction SilentlyContinue"'
      schtasks /Create /RU SYSTEM /SC ONSTART /TN $taskName /TR $cmd /F | Out-Null
    }
  } catch {}
}



