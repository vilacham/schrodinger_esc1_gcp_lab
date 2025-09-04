$domain = "${domain_name}"
$netbios = "${domain_netbios}"
$AdminPlain = "${domain_admin_password}"
$AdminPass = ConvertTo-SecureString $AdminPlain -AsPlainText -Force

# Detect if domain already exists (AD module may not be present yet on first boot)
$domainExists = $false
try { Import-Module ActiveDirectory; $null = Get-ADDomain -ErrorAction Stop; $domainExists = $true } catch { $domainExists = $false }

if (-not $domainExists) {
  # Set local Administrator password before promotion so Domain Admin inherits it
  try { net user Administrator $AdminPlain } catch {}

  # Install roles/features and promote to new forest
  Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
  Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios -SafeModeAdministratorPassword $AdminPass -InstallDNS -Force
}

# After promotion completes, create a one-time post-domain config task if not already done
# Use persistent marker location
try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
$marker = "C:\\ProgramData\\LabState\\post_domain_config.done"
if (-not (Test-Path $marker)) {
  $postScript = @'
  Import-Module ActiveDirectory
  # Skip if already configured
  try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
  $marker = "C:\\ProgramData\\LabState\\post_domain_config.done"
  if (Test-Path $marker) { return }

  # Set default domain password policy: max password age 0 (never expire)
  Set-ADDefaultDomainPasswordPolicy -Identity "$env:USERDNSDOMAIN" -MaxPasswordAge 0.00:00:00

  # Enable NTLM and disable FIPS for lab compatibility
  try { New-Item -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa\\FipsAlgorithmPolicy' -Force | Out-Null } catch {}
  try { Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa\\FipsAlgorithmPolicy' -Name Enabled -Type DWord -Value 0 } catch {}
  try { Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa' -Name LmCompatibilityLevel -Type DWord -Value 3 } catch {}

  # Create users bob and alice with given passwords and enable them (idempotent)
  $bobPass = ConvertTo-SecureString "${bob_password}" -AsPlainText -Force
  if (-not (Get-ADUser -Filter "SamAccountName -eq 'bob'" -ErrorAction SilentlyContinue)) {
    New-ADUser -Name "bob" -SamAccountName "bob" -AccountPassword $bobPass -Enabled $true
  } else {
    Enable-ADAccount -Identity bob -ErrorAction SilentlyContinue
  }

  $alicePass = ConvertTo-SecureString "${alice_password}" -AsPlainText -Force
  if (-not (Get-ADUser -Filter "SamAccountName -eq 'alice'" -ErrorAction SilentlyContinue)) {
    New-ADUser -Name "alice" -SamAccountName "alice" -AccountPassword $alicePass -Enabled $true
  } else {
    Enable-ADAccount -Identity alice -ErrorAction SilentlyContinue
  }

  New-Item -Path $marker -ItemType File -Force | Out-Null
  schtasks /Delete /TN "PostDomainConfig" /F | Out-Null
'@

  $taskScriptPath = "C:\\Windows\\Temp\\post_domain_config.ps1"
  $postScript | Out-File -FilePath $taskScriptPath -Encoding UTF8 -Force

  schtasks /Create /RU SYSTEM /SC ONSTART /TN "PostDomainConfig" /TR "powershell -ExecutionPolicy Bypass -File `"$taskScriptPath`"" /F

  # Schedule a repeating check every 5 minutes that forces replication until NTAuthCertificates has cACertificate
  $repScript = @'
  try {
    $root = [ADSI]"LDAP://RootDSE"
    $conf = $root.configurationNamingContext
    $ntAuthDn = "CN=NTAuthCertificates,CN=Public Key Services,CN=Services,$conf"
    $nt = [ADSI]("LDAP://$ntAuthDn")
    $hasCert = ($nt.Properties['cACertificate'] -and $nt.Properties['cACertificate'].Count -gt 0)
    if (-not $hasCert) {
      repadmin /syncall /APed
    } else {
      schtasks /Delete /TN "ForceConfigReplicationUntilReady" /F | Out-Null
    }
  } catch {}
'@
  $repScriptPath = "C:\\Windows\\Temp\\force_config_replication.ps1"
  $repScript | Out-File -FilePath $repScriptPath -Encoding UTF8 -Force
  schtasks /Create /RU SYSTEM /SC MINUTE /MO 5 /TN "ForceConfigReplicationUntilReady" /TR "powershell -ExecutionPolicy Bypass -File `"$repScriptPath`"" /F
}

# Enable RDP and firewall on DC (idempotent)
try {
  Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0
  Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
} catch {}


# Ensure DNS service is reachable
try {
  Start-Service DNS -ErrorAction SilentlyContinue
  Enable-NetFirewallRule -DisplayGroup "DNS Server"
} catch {}


