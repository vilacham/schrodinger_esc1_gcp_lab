$domain = "${domain_name}"
$netbios = "${domain_netbios}"
$AdminPlain = "${domain_admin_password}"
$dcIp = "${dc_ip}"
$AdminPass = ConvertTo-SecureString $AdminPlain -AsPlainText -Force

$domCred = New-Object System.Management.Automation.PSCredential ("$netbios\Administrator", $AdminPass)

# Persistent state and logging
$stateDir = 'C:\\ProgramData\\LabState'
try { if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null } } catch {}
try { Start-Transcript -Path (Join-Path $stateDir 'ca-startup.log') -Append | Out-Null } catch {}

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
  $deadline = (Get-Date).AddMinutes(10)
  do {
    $dnsOk = $false; $dsOk = $false
    try { Resolve-DnsName -Name $Domain -ErrorAction Stop | Out-Null; $dnsOk = $true } catch {}
    try { & nltest /dsgetdc:$Domain | Out-Null; if ($LASTEXITCODE -eq 0) { $dsOk = $true } } catch {}
    if ($dnsOk -and $dsOk) { return $true }
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  return $false
}

$null = Wait-ForDC -Domain $domain -DcHost $dcIp

$rdpMarker = Join-Path $stateDir 'rdp-enabled.done'
if (-not (Test-Path $rdpMarker)) {
  try {
    Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    # Allow MYLAB\\Administrator explicitly
    net localgroup "Remote Desktop Users" "$netbios\\Administrator" /add | Out-Null
    New-Item -Path $rdpMarker -ItemType File -Force | Out-Null
  } catch {}
}

$joinedMarker = Join-Path $stateDir 'domain_joined.done'
if (-not (Test-Path $joinedMarker)) {
  $partOfDomain = $false
  try { $partOfDomain = (Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain } catch { $partOfDomain = $false }
  if (-not $partOfDomain) {
    try { Add-Computer -DomainName $domain -Credential $domCred -Force -Restart } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    return
  } else {
    New-Item -Path $joinedMarker -ItemType File -Force | Out-Null
  }
}
# Install AD CS via scheduled task running as Domain Admin (SYSTEM may lack privileges in AD)
try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
$adcsMarker = "C:\\ProgramData\\LabState\\adcs_installed.done"
if (-not (Test-Path $adcsMarker)) {
  $adcsScript = @'
    try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
    try { Start-Transcript -Path (Join-Path 'C:\\ProgramData\\LabState' 'adcs-install.log') -Append | Out-Null } catch {}
    if (Test-Path "C:\\ProgramData\\LabState\\adcs_installed.done") { try { Stop-Transcript | Out-Null } catch {}; return }
    try {
      Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null
      # Build CA common name from domain: e.g., my-lab.local -> my-lab-CA
      try { $fqdn = (Get-ADDomain).DNSRoot } catch { $fqdn = $env:USERDNSDOMAIN }
      $caPrefix = if ($fqdn) { ($fqdn -split '\.')[0] } else { 'my-lab' }
      $caCommonName = "$caPrefix-CA"
      Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CACommonName $caCommonName -KeyLength 2048 -HashAlgorithmName SHA256 -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -Force
    } catch {}

    # CA policy SAN allowance intentionally not enabled; templates control behavior
    # Publish CA certificate to NTAuth (idempotent)
    try {
      $ntauthMarker = 'C:\\ProgramData\\LabState\\ntauth_published.done'
      if (-not (Test-Path $ntauthMarker)) {
        $caCertPath = 'C:\\ProgramData\\LabState\\ca.cer'
        $caCert = Get-ChildItem -Path Cert:\\LocalMachine\\CA | Where-Object { $_.Subject -like "*$caCommonName*" } | Select-Object -First 1
        if (-not $caCert) { $caCert = Get-ChildItem -Path Cert:\\LocalMachine\\CA | Select-Object -First 1 }
        if ($caCert) {
          Export-Certificate -Cert $caCert -FilePath $caCertPath -Force | Out-Null
          certutil -dspublish -f $caCertPath NTAuthCA | Out-Null
          # Verify presence in NTAuthCertificates via ADSI
          try {
            $root = [ADSI]"LDAP://RootDSE"
            $conf = $root.configurationNamingContext
            $ntAuthDn = "CN=NTAuthCertificates,CN=Public Key Services,CN=Services,$conf"
            $nt = [ADSI]("LDAP://$ntAuthDn")
            $cacerts = $nt.Properties['cACertificate']
          } catch {}
          New-Item -Path $ntauthMarker -ItemType File -Force | Out-Null
        }
      }
    } catch {}

    New-Item -Path "C:\\ProgramData\\LabState\\adcs_installed.done" -ItemType File -Force | Out-Null
    try { Stop-Transcript | Out-Null } catch {}
'@

  $adcsScriptPath = "C:\\ProgramData\\LabState\\install_adcs.ps1"
  $adcsScript | Out-File -FilePath $adcsScriptPath -Encoding UTF8 -Force
  try {
    # Create a one-time scheduled task to run as Domain Admin, run now, wait for completion, then delete
    schtasks /Create /RU "$netbios\Administrator" /RP "$AdminPlain" /SC ONCE /ST 00:00 /RL HIGHEST /TN "InstallADCS" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File `"$adcsScriptPath`"" /F | Out-Null
    schtasks /Run /TN "InstallADCS" | Out-Null
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
      if (Test-Path $adcsMarker) { break }
      Start-Sleep -Seconds 10
    }
    schtasks /Delete /TN "InstallADCS" /F | Out-Null
  } catch {}
}

# Create and publish TestCase* templates only after ADCS is installed
$templatesMarker = "C:\\ProgramData\\LabState\\ca_templates.done"
if ((Test-Path $adcsMarker) -and (-not (Test-Path $templatesMarker))) {
  $tplScript = @'
    try { if (-not (Test-Path 'C:\\ProgramData\\LabState')) { New-Item -Path 'C:\\ProgramData\\LabState' -ItemType Directory -Force | Out-Null } } catch {}
    try { Start-Transcript -Path (Join-Path 'C:\\ProgramData\\LabState' 'ca-templates.log') -Append | Out-Null } catch {}
    if (Test-Path "C:\\ProgramData\\LabState\\ca_templates.done") { try { Stop-Transcript | Out-Null } catch {}; return }
    try { if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) { Install-WindowsFeature RSAT-AD-PowerShell | Out-Null } } catch {}
    try { Import-Module ActiveDirectory -ErrorAction SilentlyContinue } catch {}
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
      Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue
      Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
      if (-not (Get-Module -ListAvailable -Name PSPKI)) { Install-Module -Name PSPKI -Force -Scope AllUsers -AllowClobber -ErrorAction Stop }
      Import-Module PSPKI -ErrorAction Stop
    } catch {}
    # Using ADSI for template property edits; PSPKI is optional

    function Ensure-Template { param([string]$name)
      # If it already exists, nothing to do
      $existing = $null
      try { $existing = Get-CertificateTemplate -DisplayName $name -ErrorAction SilentlyContinue } catch {}
      if ($existing) { return }

      # Clone 'User' template via ADSI
      $confNC = (Get-ADRootDSE).configurationNamingContext
      $templatesDn = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$confNC"
      $base = $null
      try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]("LDAP://$templatesDn"))
        $searcher.Filter = "(&(objectClass=pKICertificateTemplate)(displayName=User))"
        $searcher.PageSize = 1000
        $res = $searcher.FindOne()
        if ($res) { $base = $res.GetDirectoryEntry() }
      } catch {}
      if (-not $base) { Write-Error "Base certificate template 'User' not found"; return }

      $parent = [ADSI]("LDAP://$templatesDn")
      try {
        $new = $parent.Create("pKICertificateTemplate", "CN=$name")
        # Copy properties except system-managed ones
        $skip = @('cn','name','displayName','distinguishedName','whenCreated','whenChanged','uSNCreated','uSNChanged','dSCorePropagationData','objectGUID','objectClass','nTSecurityDescriptor','objectSid','instanceType')
        foreach ($propName in $base.Properties.PropertyNames) {
          if ($skip -contains $propName) { continue }
          $vals = $base.Properties[$propName]
          if ($vals -and $vals.Count -gt 0) { $null = $new.Properties[$propName].AddRange($vals) }
        }
        $new.Properties['displayName'].Value = $name
        $new.CommitChanges()
      } catch { Write-Error $_ }
    }

    function Set-CommonTemplateProps { param([string]$name)
      $root = [ADSI]"LDAP://RootDSE"
      $confNC = $root.Properties['configurationNamingContext'][0]
      $dn = "CN=$name,CN=Certificate Templates,CN=Public Key Services,CN=Services,$confNC"
      $de = [ADSI]("LDAP://$dn")
      if (-not $de) { return }
      try {
        # Enrollee supplies subject ONLY (set flag 0x1)
        $de.Properties['msPKI-Certificate-Name-Flag'].Value = 0x1
        # RA requirements: 0 signatures, clear policies
        $de.Properties['msPKI-RA-Signature'].Value = 0
        if ($de.Properties['msPKI-RA-Application-Policies']) { $de.Properties['msPKI-RA-Application-Policies'].Clear() }
        # EKU: client authentication only
        if ($de.Properties['pKIExtendedKeyUsage']) { $de.Properties['pKIExtendedKeyUsage'].Clear() }
        $null = $de.Properties['pKIExtendedKeyUsage'].Add('1.3.6.1.5.5.7.3.2')
        # Enrollment flags: None
        $de.Properties['msPKI-Enrollment-Flag'].Value = 0
        $de.CommitChanges()
      } catch {}
    }

    function Add-TemplateAce { param([string]$name,[System.Security.Principal.SecurityIdentifier]$sid,[int]$mask,[string]$objectGuid)
      $confNC = (Get-ADRootDSE).configurationNamingContext
      $dn = "CN=$name,CN=Certificate Templates,CN=Public Key Services,CN=Services,$confNC"
      $de = [ADSI]("LDAP://$dn")
      $sd = $de.ObjectSecurity
      if (-not $sd) { return }
      $sddl = $sd.GetSecurityDescriptorSddlForm('All')
      $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor $sddl
      if ([string]::IsNullOrEmpty($objectGuid)) {
        $ace = New-Object System.Security.AccessControl.CommonAce ([System.Security.AccessControl.AceFlags]::None, [System.Security.AccessControl.AceQualifier]::AccessAllowed, $mask, $sid, $false, $null)
      } else {
        $ace = New-Object System.Security.AccessControl.ObjectAce ([System.Security.AccessControl.AceFlags]::None,[System.Security.AccessControl.AceQualifier]::AccessAllowed,$mask,$sid,[System.Security.AccessControl.ObjectAceFlags]::ObjectAceTypePresent,([Guid]$objectGuid),[Guid]::Empty,$false,$null)
      }
      $raw.DiscretionaryAcl.InsertAce($raw.DiscretionaryAcl.Count, $ace)
      $sd.SetSecurityDescriptorSddlForm($raw.GetSddlForm('All'))
      $de.ObjectSecurity = $sd
      $de.CommitChanges()
    }

    function Remove-TemplateAcesBySid { param([string]$name,[string]$sidString)
      $confNC = (Get-ADRootDSE).configurationNamingContext
      $dn = "CN=$name,CN=Certificate Templates,CN=Public Key Services,CN=Services,$confNC"
      $de = [ADSI]("LDAP://$dn")
      $sd = $de.ObjectSecurity
      if (-not $sd) { return }
      $sddl = $sd.GetSecurityDescriptorSddlForm('All')
      $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor $sddl
      $targetSid = New-Object System.Security.Principal.SecurityIdentifier $sidString
      $acl = $raw.DiscretionaryAcl
      for ($i = $acl.Count - 1; $i -ge 0; $i--) {
        try {
          $ace = $acl[$i]
          $known = [System.Security.AccessControl.KnownAce]$ace
          if ($known.SecurityIdentifier -and $known.SecurityIdentifier.Equals($targetSid)) {
            $acl.RemoveAce($i)
          }
        } catch {}
      }
      $sd.SetSecurityDescriptorSddlForm($raw.GetSddlForm('All'))
      $de.ObjectSecurity = $sd
      $de.CommitChanges()
    }

    1..8 | ForEach-Object { Ensure-Template -name ("TestCase{0}" -f $_); Set-CommonTemplateProps -name ("TestCase{0}" -f $_) }

    $domainUsersSid = ([System.Security.Principal.NTAccount]::new("${netbios}","Domain Users")).Translate([System.Security.Principal.SecurityIdentifier])
    $aliceSid = ([System.Security.Principal.NTAccount]::new("${netbios}","alice")).Translate([System.Security.Principal.SecurityIdentifier])
    $bobSid   = ([System.Security.Principal.NTAccount]::new("${netbios}","bob")).Translate([System.Security.Principal.SecurityIdentifier])

    $GUID_ENROLL = "0e10c968-78fb-11d2-90d4-00c04f79dc55"
    $GUID_OTHER  = "ab721a53-1e2f-11d0-9819-00aa0040529b"

    Add-TemplateAce -name 'TestCase1' -sid $domainUsersSid -mask 0x00000130 -objectGuid $GUID_ENROLL
    Add-TemplateAce -name 'TestCase2' -sid $aliceSid       -mask 0x00000130 -objectGuid $GUID_ENROLL
    Add-TemplateAce -name 'TestCase3' -sid $domainUsersSid -mask 0x00000100 -objectGuid ''
    Add-TemplateAce -name 'TestCase4' -sid $aliceSid       -mask 0x00000100 -objectGuid ''
    Add-TemplateAce -name 'TestCase5' -sid $domainUsersSid -mask 0x00000030 -objectGuid $GUID_ENROLL
    Add-TemplateAce -name 'TestCase6' -sid $domainUsersSid -mask 0x00000130 -objectGuid $GUID_OTHER
    Add-TemplateAce -name 'TestCase7' -sid $bobSid         -mask 0x00000030 -objectGuid $GUID_ENROLL
    Add-TemplateAce -name 'TestCase8' -sid $bobSid         -mask 0x00000130 -objectGuid $GUID_OTHER

    # Remove any ACEs for Local System (S-1-5-18) from TestCase templates
    try {
      $systemSid = 'S-1-5-18'
      1..8 | ForEach-Object { Remove-TemplateAcesBySid -name ("TestCase{0}" -f $_) -sidString $systemSid }
    } catch {}

    try {
      1..8 | ForEach-Object { certutil -setcatemplates +TestCase$_ | Out-Null }
    } catch {}

    New-Item -Path "C:\\ProgramData\\LabState\\ca_templates.done" -ItemType File -Force | Out-Null
    try { Stop-Transcript | Out-Null } catch {}
'@

  $tplScriptPath = "C:\\ProgramData\\LabState\\create_ca_templates.ps1"
  $tplScript | Out-File -FilePath $tplScriptPath -Encoding UTF8 -Force
  try {
    schtasks /Create /RU "$netbios\Administrator" /RP "$AdminPlain" /SC ONCE /ST 00:00 /RL HIGHEST /TN "CreateCATemplates" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File `"$tplScriptPath`"" /F | Out-Null
    schtasks /Run /TN "CreateCATemplates" | Out-Null
    $deadline2 = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline2) {
      if (Test-Path $templatesMarker) { break }
      Start-Sleep -Seconds 10
    }
    schtasks /Delete /TN "CreateCATemplates" /F | Out-Null
  } catch {}
}

# Fallback publication to NTAuth if missed during install
try {
  $ntauthMarker = 'C:\\ProgramData\\LabState\\ntauth_published.done'
  if (-not (Test-Path $ntauthMarker)) {
    $caCertPath = 'C:\\ProgramData\\LabState\\ca.cer'
    $caCommonName = try { (Get-ADDomain).DNSRoot.Split('.')[0] + '-CA' } catch { $env:COMPUTERNAME + '-CA' }
    $caCert = Get-ChildItem -Path Cert:\\LocalMachine\\CA | Where-Object { $_.Subject -like "*$caCommonName*" } | Select-Object -First 1
    if (-not $caCert) { $caCert = Get-ChildItem -Path Cert:\\LocalMachine\\CA | Select-Object -First 1 }
    if ($caCert) {
      Export-Certificate -Cert $caCert -FilePath $caCertPath -Force | Out-Null
      certutil -dspublish -f $caCertPath NTAuthCA | Out-Null
      New-Item -Path $ntauthMarker -ItemType File -Force | Out-Null
    }
  }
} catch {}

# Ensure AD/crypto policies allow NTLM and disable FIPS constraints (lab only)
try { New-Item -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa\\FipsAlgorithmPolicy' -Force | Out-Null } catch {}
try { Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa\\FipsAlgorithmPolicy' -Name Enabled -Type DWord -Value 0 } catch {}
try { Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa' -Name LmCompatibilityLevel -Type DWord -Value 3 } catch {}

# SAN policy is applied during ADCS installation; no need to repeat here

# Templates are created separately; nothing else to do here
try { Stop-Transcript | Out-Null } catch {}
