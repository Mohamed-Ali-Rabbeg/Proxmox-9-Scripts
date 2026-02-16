########################################################################
# Windows Server Template Preparation Script for Proxmox + Cloudbase-Init
# Compatible: Windows Server 2019 / 2022 / 2025 Datacenter
# Purpose: Prepares a fresh Windows Server install for templating
# Author: Hydra RABBEG
# Version: 1.0.5
# Usage: Run as Administrator in PowerShell after fresh OS installation
#     Note:     VirtIO ISO Should be mounted
########################################################################

param(
    [switch]$SkipSysprep,
    [switch]$SkipUpdates,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# =====================================================================
# COLORS AND LOGGING
# =====================================================================
function Write-Step($step, $msg) { Write-Host "`n[$step] $msg" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

$logFile = "C:\Windows\Temp\template-prep.log"
try {
    Start-Transcript -Path $logFile -Force -ErrorAction Stop
    Write-Host "Transcript started, output file is $logFile" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not start transcript: $_" -ForegroundColor Yellow
}

Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  WINDOWS SERVER TEMPLATE PREPARATION FOR PROXMOX" -ForegroundColor Yellow
Write-Host "  Cloudbase-Init + Password Injection + Optimization" -ForegroundColor Yellow
Write-Host "  Version: 1.0.5 -Hydra@Rabbeg" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

$osVersion = (Get-WmiObject Win32_OperatingSystem).Caption
$osShort = ""
if ($osVersion -match "2019") { $osShort = "2K19" }
elseif ($osVersion -match "2022") { $osShort = "2K22" }
elseif ($osVersion -match "2025") { $osShort = "2K25" }
else { $osShort = "SVR" }

Write-Host "Detected OS: $osVersion" -ForegroundColor White
Write-Host ""
# =====================================================================
# STEP 0 : INSTALL GOOGLE CHROME
# =====================================================================
Write-Step "0/18" "Installing Google Chrome"

$chromeInstalled = (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") -or
                   (Test-Path "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe") -or
                   (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Google Chrome" })
if ($chromeInstalled) {
    Write-Warn "Google Chrome already installed, skipping"
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $chromeUrl = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
    $chromeInstaller = "$env:TEMP\chrome_installer.exe"
    Write-Host "  Downloading Google Chrome..." -ForegroundColor White
    try {
        Invoke-WebRequest -Uri $chromeUrl -OutFile $chromeInstaller -UseBasicParsing
        Write-OK "Downloaded"
        Write-Host "  Installing Google Chrome..." -ForegroundColor White
        Start-Process $chromeInstaller -ArgumentList "/silent /install" -Wait
        Remove-Item $chromeInstaller -Force -ErrorAction SilentlyContinue
        Write-OK "Google Chrome installed"
    } catch {
        Write-Warn "Could not download Chrome (no internet?). Skipping."
    }
}
# =====================================================================
# STEP 1: CHECK AND INSTALL VIRTIO DRIVERS + QEMU GUEST AGENT
# =====================================================================
Write-Step "1/19" "Checking VirtIO Drivers and QEMU Guest Agent"

# Check if QEMU Guest Agent is already installed
$qemuInstalled = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($qemuInstalled) {
    Write-OK "QEMU Guest Agent is already installed"
} else {
    Write-Warn "QEMU Guest Agent not found - will install from VirtIO ISO"
}

# Find VirtIO ISO drive
$virtioDrive = $null
$cdDrives = Get-WmiObject -Class Win32_CDROMDrive
foreach ($drive in $cdDrives) {
    if ($drive.MediaLoaded -and $drive.VolumeName -like "*VIRTIO*") {
        $virtioDrive = $drive.Drive
        Write-OK "Found VirtIO ISO mounted at $virtioDrive with label: $($drive.VolumeName)"
        break
    }
}

if (-not $virtioDrive) {
    Write-Err "VirtIO ISO not found! Please mount the VirtIO ISO file and try again."
    Write-Host "Available CD/DVD drives:" -ForegroundColor Yellow
    $cdDrives | ForEach-Object { Write-Host "  $($_.Drive) - $($_.VolumeName) (Media loaded: $($_.MediaLoaded))" }
    try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
    exit 1
}

# Install VirtIO drivers if needed
Write-Host "`n  Installing VirtIO drivers from $virtioDrive..." -ForegroundColor White

$driverTypes = @(
    @{Name="Network (NetKVM)"; Path="$virtioDrive\NetKVM\2k22\amd64"},
    @{Name="Block (viostor)"; Path="$virtioDrive\viostor\2k22\amd64"},
    @{Name="Balloon (balloon)"; Path="$virtioDrive\balloon\2k22\amd64"}
)

foreach ($driver in $driverTypes) {
    Write-Host "  Installing $($driver.Name) drivers..." -ForegroundColor Gray
    if (Test-Path $driver.Path) {
        pnputil /add-driver "$($driver.Path)\*.inf" /install
        Write-OK "$($driver.Name) drivers installed"
    } else {
        Write-Warn "Driver path not found: $($driver.Path)"
    }
}

# Install QEMU Guest Agent if not already installed
if (-not $qemuInstalled) {
    Write-Host "`n  Installing QEMU Guest Agent..." -ForegroundColor White
    
    # Find QEMU GA installer (usually in guest-agent folder)
    $qemuGaPaths = @(
        "$virtioDrive\guest-agent\qemu-ga-x86_64.msi",
        "$virtioDrive\guest-agent\qemu-ga-x64.msi",
        "$virtioDrive\guest-agent\*.msi"
    )
    
    $qemuGaInstaller = $null
    foreach ($path in $qemuGaPaths) {
        $files = Get-ChildItem $path -ErrorAction SilentlyContinue
        if ($files) {
            $qemuGaInstaller = $files[0].FullName
            break
        }
    }
    
    if ($qemuGaInstaller) {
        Write-Host "  Found QEMU GA installer: $qemuGaInstaller" -ForegroundColor Gray
        Write-Host "  Installing QEMU Guest Agent..." -ForegroundColor Gray
        Start-Process msiexec.exe -ArgumentList "/i `"$qemuGaInstaller`" /qn /norestart" -Wait
        Write-OK "QEMU Guest Agent installed"
        
        # Start the service
        Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
        Set-Service -Name "QEMU-GA" -StartupType Automatic
        Write-OK "QEMU Guest Agent service started and set to automatic"
    } else {
        Write-Err "Could not find QEMU Guest Agent installer on VirtIO ISO"
    }
}

# Verify QEMU Guest Agent is running
$qemuService = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($qemuService) {
    Write-OK "QEMU Guest Agent status: $($qemuService.Status)"
} else {
    Write-Warn "QEMU Guest Agent service not found"
}

Write-Host "`n  VirtIO driver installation complete. Installed drivers:" -ForegroundColor White
pnputil /enum-drivers | Select-String "virtio|qemu" -Context 0,2
Write-OK "VirtIO drivers installation completed"

# =====================================================================
# STEP 2: SET TIMEZONE TO PARIS (UTC+1)
# =====================================================================
Write-Step "2/19" "Setting Timezone to Paris (Romance Standard Time / UTC+1)"

Set-TimeZone -Id "Romance Standard Time"
$tz = Get-TimeZone
Write-OK "Timezone set to: $($tz.DisplayName)"

Write-Host "  Configuring NTP time sync..." -ForegroundColor White
w32tm /config /manualpeerlist:"time.windows.com,0x1 pool.ntp.org,0x1" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time -ErrorAction SilentlyContinue
w32tm /resync /force
Write-OK "NTP time sync configured"

# =====================================================================
# STEP 3: SET PROFESSIONAL HOSTNAME
# =====================================================================
Write-Step "3/19" "Setting Professional Hostname"

$randomSuffix = -join ((65..90) + (48..57) | Get-Random -Count 10 | ForEach-Object { [char]$_ })
$newHostname = "WIN-$osShort-$randomSuffix"
Write-Host "  Current hostname: $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host "  New hostname: $newHostname" -ForegroundColor White
Write-Warn "Note: Hostname will be overridden by Cloudbase-init on clone deployment"

Rename-Computer -NewName $newHostname -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
Write-OK "Hostname set to $newHostname (template default)"

# =====================================================================
# STEP 4: WINDOWS UPDATES (SILENT MODE)
# =====================================================================
Write-Step "4/19" "Running Windows Updates (Silent Mode)"

if ($SkipUpdates) {
    Write-Warn "Windows Updates skipped (-SkipUpdates flag)"
} else {
    Write-Host "  Installing NuGet provider..." -ForegroundColor White
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Warn "NuGet installation had non-critical errors, continuing..."
    }

    Write-Host "  Installing PSWindowsUpdate module..." -ForegroundColor White
    try {
        Install-Module PSWindowsUpdate -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Warn "PSWindowsUpdate module installation had non-critical errors, continuing..."
    }

    Write-Host "  Checking for updates (this may take 10-30 minutes)..." -ForegroundColor White
    Write-Host "  Please be patient..." -ForegroundColor Yellow

    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
        if ($updates) {
            Write-Host "  Found $($updates.Count) update(s). Installing..." -ForegroundColor White
            Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-OK "Windows Updates installed ($($updates.Count) updates)"
        } else {
            Write-OK "No updates available - system is up to date"
        }
    } catch {
        Write-Warn "PSWindowsUpdate module failed, trying built-in method silently..."
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $results = $searcher.Search("IsInstalled=0")

            if ($results.Updates.Count -gt 0) {
                Write-Host "  Found $($results.Updates.Count) update(s). Installing..." -ForegroundColor White
                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $results.Updates
                $downloader.Download() | Out-Null

                $installer = $session.CreateUpdateInstaller()
                $installer.Updates = $results.Updates
                $installResult = $installer.Install()

                Write-OK "Windows Updates installed ($($results.Updates.Count) updates)"
                if ($installResult.RebootRequired) {
                    Write-Warn "Reboot may be required after updates"
                }
            } else {
                Write-OK "No updates available - system is up to date"
            }
        } catch {
            Write-Warn "Windows update check failed: $_"
        }
    }
}

# =====================================================================
# STEP 5: ENABLE RDP
# =====================================================================
Write-Step "5/19" "Enabling Remote Desktop (RDP)"

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Write-OK "RDP enabled"

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0
Write-OK "NLA disabled (RDP works without console pre-login)"

Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
Write-OK "RDP firewall rules enabled"

# =====================================================================
# STEP 6: WINDOWS OPTIMIZATION
# =====================================================================
Write-Step "6/19" "Optimizing Windows Performance"

Write-Host "  Disabling hibernation..." -ForegroundColor White
powercfg /h off
Write-OK "Hibernation disabled"

Write-Host "  Disabling pagefile..." -ForegroundColor White
try {
    $cs = Get-WmiObject Win32_ComputerSystem
    $cs.AutomaticManagedPagefile = $false
    $cs.Put()
} catch {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -Value ""
}
$pf = Get-WmiObject Win32_PageFileSetting -ErrorAction SilentlyContinue
if ($pf) { $pf.Delete() }
Write-OK "Pagefile disabled (auto-created per VM)"

Write-Host "  Setting High Performance power plan..." -ForegroundColor White
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Write-OK "Power plan set to High Performance"

Write-Host "  Disabling unnecessary services..." -ForegroundColor White
$services = @(
    'DiagTrack',           # Connected User Experiences and Telemetry
    'dmwappushservice',    # WAP Push Message Routing Service
    'WSearch',             # Windows Search
    'SysMain',             # Superfetch
    'MapsBroker',          # Downloaded Maps Manager
    'lfsvc',               # Geolocation Service
    'RetailDemo',          # Retail Demo Service
    'WerSvc',              # Windows Error Reporting
    'Fax',                 # Fax Service
    'XblAuthManager',      # Xbox Live Auth Manager
    'XblGameSave',         # Xbox Live Game Save
    'XboxNetApiSvc',       # Xbox Live Networking Service
    'wisvc',               # Windows Insider Service
    'icssvc',              # Windows Mobile Hotspot Service
    'WMPNetworkSvc',       # Windows Media Player Network Sharing
    'PhoneSvc'             # Phone Service
)
foreach ($svc in $services) {
    Write-Host "    Disabling $svc..." -ForegroundColor Gray
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
Write-OK "Unnecessary services disabled ($($services.Count) services)"

Write-Host "  Disabling Server Manager auto-launch..." -ForegroundColor White
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
Write-OK "Server Manager auto-launch disabled"

Write-Host "  Disabling IE Enhanced Security Configuration..." -ForegroundColor White
$AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0 -ErrorAction SilentlyContinue
Write-OK "IE Enhanced Security Configuration disabled"

# =====================================================================
# STEP 7: DISABLE AUTOMATIC WINDOWS UPDATES
# =====================================================================
Write-Step "7/19" "Disabling Automatic Windows Updates (post-template)"

$WUKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (!(Test-Path $WUKey)) { New-Item -Path $WUKey -Force }
Set-ItemProperty -Path $WUKey -Name "NoAutoUpdate" -Value 1
Set-ItemProperty -Path $WUKey -Name "AUOptions" -Value 2
Write-OK "Automatic updates disabled (notify only)"

Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
Write-OK "Windows Update service set to manual"

# =====================================================================
# STEP 8: PASSWORD POLICY
# =====================================================================
Write-Step "8/19" "Configuring Password Policy"

Write-Host "  Setting maximum password age to unlimited..." -ForegroundColor White
net accounts /maxpwage:unlimited
Write-OK "Maximum password age set to unlimited"

Write-Host "  Disabling Administrator password change at logon..." -ForegroundColor White
net user Administrator /logonpasswordchg:no
Write-OK "Administrator password change at logon disabled"

Write-Host "  Enabling Administrator account..." -ForegroundColor White
net user Administrator /active:yes
Write-OK "Administrator account enabled"

Write-Host "  Setting Administrator password to never expire..." -ForegroundColor White
$admin = [ADSI]"WinNT://./Administrator,user"
$admin.UserFlags = $admin.UserFlags.Value -bor 0x10000
$admin.SetInfo()
Write-OK "Administrator password set to never expire"

# =====================================================================
# STEP 9: DELETE RECOVERY PARTITION
# =====================================================================
Write-Step "9/19" "Deleting Recovery Partition"

$recoveryFound = $false
$partitions = Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue
foreach ($part in $partitions) {
    if ($part.Type -eq "Recovery") {
        Write-Warn "Found recovery partition: Partition $($part.PartitionNumber), Size: $([math]::Round($part.Size/1MB))MB"
        Write-Host "  Disabling Windows Recovery Environment..." -ForegroundColor White
        reagentc /disable
        Write-Host "  Deleting recovery partition $($part.PartitionNumber)..." -ForegroundColor White
        $removeScript = @"
select disk 0
select partition $($part.PartitionNumber)
delete partition override
"@
        $removeScript | diskpart
        $recoveryFound = $true
        Write-OK "Recovery partition $($part.PartitionNumber) deleted"
    }
}

if (-not $recoveryFound) {
    Write-OK "No recovery partition found (already clean)"
}

Write-Host "  Disabling Windows Recovery Environment..." -ForegroundColor White
reagentc /disable
Write-OK "Windows Recovery Environment disabled"

# =====================================================================
# STEP 10: EXTEND PRIMARY PARTITION
# =====================================================================
Write-Step "10/19" "Extending Primary Partition"

$maxSize = (Get-PartitionSupportedSize -DriveLetter C -ErrorAction SilentlyContinue).SizeMax
$currentSize = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).Size
if ($maxSize -and $currentSize -and ($maxSize -gt $currentSize)) {
    Write-Host "  Extending C: drive from $([math]::Round($currentSize/1GB,2))GB to $([math]::Round($maxSize/1GB,2))GB..." -ForegroundColor White
    Resize-Partition -DriveLetter C -Size $maxSize
    Write-OK "C: drive extended to fill available space"
} else {
    Write-OK "C: drive already at maximum size"
}

# =====================================================================
# STEP 11: INSTALL CLOUDBASE-INIT
# =====================================================================
Write-Step "11/19" "Installing Cloudbase-Init"

$cbInstalled = Test-Path "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
if ($cbInstalled) {
    Write-Warn "Cloudbase-Init already installed, skipping download"
} else {
    $cbUrl = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
    $cbPath = "$env:TEMP\CloudbaseInitSetup.msi"

    Write-Host "  Downloading Cloudbase-Init..." -ForegroundColor White
    Invoke-WebRequest -Uri $cbUrl -OutFile $cbPath -UseBasicParsing
    Write-OK "Downloaded"

    Write-Host "  Installing Cloudbase-Init..." -ForegroundColor White
    Start-Process msiexec.exe -ArgumentList "/i $cbPath /qn /norestart" -Wait
    Write-OK "Installed"

    Write-Host "  Removing default cloudbase-init user..." -ForegroundColor White
    net user cloudbase-init /delete
    Write-OK "Removed cloudbase-init service user"
}

Write-Host "  Setting Cloudbase-Init service to run as LocalSystem..." -ForegroundColor White
sc.exe config cloudbase-init obj= LocalSystem
Write-OK "Cloudbase-Init service set to run as LocalSystem"

# =====================================================================
# STEP 12: CONFIGURE CLOUDBASE-INIT
# =====================================================================
Write-Step "12/19" "Configuring Cloudbase-Init for Proxmox"

$cbConfPath = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"

Write-Host "  Writing cloudbase-init.conf..." -ForegroundColor White
@"
[DEFAULT]
username=Administrator
inject_user_password=true
first_logon_behaviour=no
password_expires=false
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
allow_reboot=false
stop_service_on_exit=false
log_dir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
log_file=cloudbase-init.log
check_latest_version=false
"@ | Set-Content "$cbConfPath\cloudbase-init.conf" -Force
Write-OK "Main config written"

Write-Host "  Writing cloudbase-init-unattend.conf..." -ForegroundColor White
@"
[DEFAULT]
username=Administrator
inject_user_password=true
first_logon_behaviour=no
password_expires=false
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin
allow_reboot=false
stop_service_on_exit=false
log_dir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
log_file=cloudbase-init-unattend.log
check_latest_version=false
"@ | Set-Content "$cbConfPath\cloudbase-init-unattend.conf" -Force
Write-OK "Unattend config written"

Write-Host "  Writing Unattend.xml..." -ForegroundColor White
@'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value></Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Path>cmd.exe /c ""C:\Program Files\Cloudbase Solutions\Cloudbase-Init\Python\Scripts\cloudbase-init.exe" --config-file "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf" &amp;&amp; exit 1 || exit 2"</Path>
          <Description>Run Cloudbase-Init</Description>
          <WillReboot>OnRequest</WillReboot>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@ | Set-Content "$cbConfPath\Unattend.xml" -Encoding UTF8 -Force
Write-OK "Unattend.xml written"

# =====================================================================
# STEP 13: CREATE PASSWORD INJECTION SCRIPTS
# =====================================================================
Write-Step "13/19" "Creating Password Injection Scripts"

$scriptDir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts"
if (!(Test-Path $scriptDir)) { New-Item -Path $scriptDir -ItemType Directory -Force }

Write-Host "  Creating SetPassword.ps1..." -ForegroundColor White
@'
# SetPassword - Reads cloud-init config drive and sets Administrator password
# Supports hidden CD-ROM (no drive letter) via volume label detection
$userData = $null

# Method 1: Check all lettered drives
Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
    $paths = @(
        "$($_.Root)user-data",
        "$($_.Root)openstack\latest\user_data"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $userData = Get-Content $p -Raw
            break
        }
    }
}

# Method 2: Find by volume label if not found above (hidden CD-ROM)
if (-not $userData) {
    $vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.Label -eq "config-2" -or $_.Label -eq "cidata" }
    if ($vol) {
        $mountPoint = $vol.DeviceID
        $paths = @(
            "${mountPoint}user-data",
            "${mountPoint}openstack\latest\user_data"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                $userData = Get-Content $p -Raw
                break
            }
        }
    }
}

if ($userData) {
    if ($userData -match "password:\s*(.+)") {
        $password = $Matches[1].Trim()
        $username = "Administrator"
        if ($userData -match "user:\s*(.+)") {
            $username = $Matches[1].Trim()
        }
        net user $username "$password"
        $user = [ADSI]"WinNT://./$username,user"
        $user.UserFlags = $user.UserFlags.Value -bor 0x10000
        $user.SetInfo()
    }
}
'@ | Set-Content "$scriptDir\SetPassword.ps1" -Force
Write-OK "SetPassword.ps1 created (boot-time password injection)"

Write-Host "  Creating PasswordWatcher.ps1..." -ForegroundColor White
@'
# PasswordWatcher - Monitors cloud-init drive for password changes in real-time
# Runs as a persistent background task, checks every 10 seconds
# Hash comparison ensures near-zero CPU usage
$logFile = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\password-sync.log"

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg" | Out-File $logFile -Append
}

function Get-CloudInitUserData {
    $userData = $null

    # Method 1: Lettered drives
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        $paths = @(
            "$($_.Root)user-data",
            "$($_.Root)openstack\latest\user_data"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                $userData = Get-Content $p -Raw
                break
            }
        }
    }

    # Method 2: Volume label (hidden CD-ROM)
    if (-not $userData) {
        $vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.Label -eq "config-2" -or $_.Label -eq "cidata" }
        if ($vol) {
            $mountPoint = $vol.DeviceID
            $paths = @(
                "${mountPoint}user-data",
                "${mountPoint}openstack\latest\user_data"
            )
            foreach ($p in $paths) {
                if (Test-Path $p) {
                    $userData = Get-Content $p -Raw
                    break
                }
            }
        }
    }

    return $userData
}

function Apply-Password {
    $userData = Get-CloudInitUserData
    if (-not $userData) { return }

    if ($userData -match "password:\s*(.+)") {
        $newPassword = $Matches[1].Trim()
    } else { return }

    $username = "Administrator"
    if ($userData -match "user:\s*(.+)") {
        $username = $Matches[1].Trim()
    }

    $hashFile = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\.pw_hash"
    $newHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($newPassword)
        )
    )

    $oldHash = ""
    if (Test-Path $hashFile) { $oldHash = (Get-Content $hashFile -Raw).Trim() }

    if ($newHash -ne $oldHash) {
        $result = net user $username "$newPassword" 2>&1
        $user = [ADSI]"WinNT://./$username,user"
        $user.UserFlags = $user.UserFlags.Value -bor 0x10000
        $user.SetInfo()
        $newHash | Set-Content $hashFile -Force
        Write-Log "Password updated for $username (result: $result)"
    }
}

Write-Log "PasswordWatcher started"
Apply-Password

while ($true) {
    Start-Sleep -Seconds 10
    try {
        Apply-Password
    } catch {
        Write-Log "Error: $_"
    }
}
'@ | Set-Content "$scriptDir\PasswordWatcher.ps1" -Force
Write-OK "PasswordWatcher.ps1 created (real-time password sync every 10s)"

Write-Host "  Creating HideCDROM.ps1..." -ForegroundColor White
@'
# Hide cloud-init CD-ROM drive letter at startup
$vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.Label -eq "config-2" -or $_.Label -eq "cidata" }
if ($vol -and $vol.DriveLetter) {
    $vol.DriveLetter = $null
    $vol.Put()
}
'@ | Set-Content "$scriptDir\HideCDROM.ps1" -Force
Write-OK "HideCDROM.ps1 created (hides cloud-init CD-ROM from users)"

Write-Host "  Hiding cloud-init CD-ROM immediately..." -ForegroundColor White
$vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.Label -eq "config-2" -or $_.Label -eq "cidata" }
if ($vol -and $vol.DriveLetter) {
    $vol.DriveLetter = $null
    $vol.Put()
    Write-OK "Cloud-init CD-ROM hidden immediately"
} else {
    Write-OK "Cloud-init CD-ROM already hidden or not present"
}

# =====================================================================
# STEP 14: CREATE SCHEDULED TASKS
# =====================================================================
Write-Step "14/19" "Creating Scheduled Tasks"

Write-Host "  Removing existing tasks..." -ForegroundColor White
Unregister-ScheduledTask -TaskName "CloudInit-PasswordSync" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "CloudInit-PasswordWatcher" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "HideCloudInitCDROM" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "  Creating PasswordWatcher task..." -ForegroundColor White
$pwAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDir\PasswordWatcher.ps1`""
$pwTrigger = New-ScheduledTaskTrigger -AtStartup
$pwSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)
$pwPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "CloudInit-PasswordWatcher" -Action $pwAction -Trigger $pwTrigger `
    -Settings $pwSettings -Principal $pwPrincipal -Force
Write-OK "PasswordWatcher task registered (persistent, 10s interval)"

Write-Host "  Creating HideCDROM task..." -ForegroundColor White
$hideAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDir\HideCDROM.ps1`""
$hideTrigger = New-ScheduledTaskTrigger -AtStartup
$hideSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$hidePrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "HideCloudInitCDROM" -Action $hideAction -Trigger $hideTrigger `
    -Settings $hideSettings -Principal $hidePrincipal -Force
Write-OK "HideCDROM task registered (startup)"

# =====================================================================
# STEP 15: DEEP DISK CLEANUP
# =====================================================================
Write-Step "15/19" "Deep Disk Cleanup"

$freeBefore = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
Write-Host "  C: Free space before cleanup: ${freeBefore}GB" -ForegroundColor Gray

Write-Host "  Cleaning SoftwareDistribution folder..." -ForegroundColor White
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\*" -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Write-OK "SoftwareDistribution fully cleaned"

Write-Host "  Running DISM Component Store cleanup (this may take a few minutes)..." -ForegroundColor White
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
Write-OK "Component Store cleaned (WinSxS)"

Write-Host "  Cleaning Windows Installer patch cache..." -ForegroundColor White
Remove-Item -Recurse -Force 'C:\Windows\Installer\$PatchCache$\*' -ErrorAction SilentlyContinue
Write-OK "Installer patch cache cleaned"

Write-Host "  Removing Windows old/upgrade leftovers..." -ForegroundColor White
Remove-Item -Recurse -Force "C:\Windows.old" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Downloaded Program Files\*" -ErrorAction SilentlyContinue
Write-OK "Old Windows files cleaned"

Write-Host "  Cleaning CBS/DISM logs..." -ForegroundColor White
Remove-Item -Force "C:\Windows\Logs\CBS\*.log" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Windows\Logs\DISM\*.log" -ErrorAction SilentlyContinue
Write-OK "CBS/DISM logs cleaned"

Write-Host "  Cleaning Temp folders..." -ForegroundColor White
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\*\AppData\Local\Temp\*" -ErrorAction SilentlyContinue
Write-OK "Temp folders cleaned"

Write-Host "  Cleaning Prefetch..." -ForegroundColor White
Remove-Item -Recurse -Force "C:\Windows\Prefetch\*" -ErrorAction SilentlyContinue
Write-OK "Prefetch cleaned"

Write-Host "  Flushing DNS cache..." -ForegroundColor White
ipconfig /flushdns
Write-OK "DNS cache flushed"

Write-Host "  Cleaning thumbnail cache..." -ForegroundColor White
try {
    # Try to stop Explorer to release file locks
    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    $thumbCachePaths = @(
        "C:\Users\*\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*",
        "C:\Users\*\AppData\Local\Microsoft\Windows\Explorer\*.db"
    )
    
    foreach ($path in $thumbCachePaths) {
        Get-ChildItem $path -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue
            } catch {
                # Skip files that can't be deleted
                Write-Host "      (Skipped: $($_.Name) - in use)" -ForegroundColor DarkGray
            }
        }
    }
    
    # Restart Explorer
    Start-Process "explorer.exe" -WindowStyle Hidden
} catch {
    Write-Warn "Some thumbnail cache files could not be deleted (they're in use)"
}
Write-OK "Thumbnail cache cleaned"

Write-Host "  Cleaning recent files..." -ForegroundColor White
Remove-Item -Recurse -Force "C:\Users\*\AppData\Roaming\Microsoft\Windows\Recent\*" -ErrorAction SilentlyContinue
Write-OK "Recent files cleaned"

Write-Host "  Cleaning Cloudbase-init logs and hash file..." -ForegroundColor White
Remove-Item -Force "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\*.log" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\.pw_hash" -ErrorAction SilentlyContinue
Write-OK "Cloudbase-init logs and hash file cleaned"

Write-Host "  Cleaning Windows Error Reports..." -ForegroundColor White
Remove-Item -Recurse -Force "C:\ProgramData\Microsoft\Windows\WER\*" -ErrorAction SilentlyContinue
Write-OK "Windows Error Reports cleaned"

Write-Host "  Emptying Recycle Bin..." -ForegroundColor White
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-OK "Recycle Bin emptied"

Write-Host "  Removing default IIS folder..." -ForegroundColor White
if (Test-Path "C:\inetpub") {
    Remove-Item -Recurse -Force "C:\inetpub" -ErrorAction SilentlyContinue
    Write-OK "Default IIS folder (inetpub) removed"
}

Write-Host "  Cleaning additional system files..." -ForegroundColor White
Remove-Item -Recurse -Force "C:\Windows\Downloaded Program Files\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\System32\LogFiles\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\ProgramData\Microsoft\Windows Defender\Scans\History\*" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Windows\setupact.log" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Windows\setuperr.log" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Windows\*.log" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Minidump\*" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\Windows\MEMORY.DMP" -ErrorAction SilentlyContinue
Write-OK "Additional system files cleaned"

$freeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
$saved = [math]::Round($freeAfter - $freeBefore, 2)
Write-Host ""
Write-Host "  C: Free space after cleanup: ${freeAfter}GB (saved ${saved}GB)" -ForegroundColor Yellow

# =====================================================================
# STEP 16: REMOVE TEMPLATE PREP SCRIPTS
# =====================================================================
Write-Step "16/19" "Removing Template Prep Scripts"

Remove-Item -Force "C:\WinServer-Template-Prep.ps1" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\WinServer-Template-Prep-v2.ps1" -ErrorAction SilentlyContinue
Remove-Item -Force "C:\WinServer-Template-Prep-v3.ps1" -ErrorAction SilentlyContinue
Write-OK "Template prep scripts removed from C:\"

# =====================================================================
# STEP 17: CLEAN ALL EVENT LOGS AND POWERSHELL HISTORY (SILENT MODE)
# =====================================================================
Write-Step "17/19" "Cleaning All Event Logs and PowerShell History (Silent Mode)"

Write-Host "  Cleaning all Windows event logs (this may take a few minutes)..." -ForegroundColor Yellow

# Track errors
$errorCount = 0
$errorMessages = @()

# Method 1: Clear standard event logs using Clear-EventLog
try {
    $standardLogs = @(
        "Application", "Security", "Setup", "System", "ForwardedEvents",
        "HardwareEvents", "Internet Explorer", "Key Management Service",
        "Windows PowerShell"
    )
    
    foreach ($log in $standardLogs) {
        try {
            Clear-EventLog -LogName $log -ErrorAction SilentlyContinue
        } catch {
            # Ignore - log might not exist
        }
    }
} catch {
    $errorCount++
    $errorMessages += "Error clearing standard logs: $_"
}

# Method 2: Use wevtutil to get ALL logs and clear them silently
try {
    $allLogs = wevtutil el 2>$null
    $logCount = ($allLogs | Measure-Object).Count
    
    foreach ($logName in $allLogs) {
        try {
            wevtutil cl "$logName" 2>$null
        } catch {
            # Silently fail for individual logs
        }
    }
} catch {
    $errorCount++
    $errorMessages += "Error clearing logs with wevtutil: $_"
}

# Method 3: Explicitly clear critical logs and remove .evtx files
try {
    $criticalLogs = @("Application", "Security", "Setup", "System", "ForwardedEvents")
    
    # Stop Event Log service temporarily
    Stop-Service -Name EventLog -Force -ErrorAction SilentlyContinue
    
    foreach ($log in $criticalLogs) {
        try {
            wevtutil cl "$log" 2>$null
            $evtxPath = "C:\Windows\System32\winevt\Logs\$log.evtx"
            if (Test-Path $evtxPath) {
                Remove-Item -Force $evtxPath -ErrorAction SilentlyContinue
            }
        } catch {
            # Silently fail
        }
    }
    
    # Start Event Log service
    Start-Service -Name EventLog -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
} catch {
    $errorCount++
    $errorMessages += "Error cleaning critical logs: $_"
}

# Clean PowerShell event logs
try {
    $psEventLogs = @(
        "Windows PowerShell",
        "Microsoft-Windows-PowerShell/Operational",
        "Microsoft-Windows-PowerShell/Analytic",
        "Microsoft-Windows-PowerShell/Admin",
        "PowerShellCore/Operational",
        "PowerShellCore/Analytic",
        "PowerShellCore/Admin"
    )
    
    foreach ($log in $psEventLogs) {
        try {
            wevtutil cl "$log" 2>$null
        } catch {
            # Silently fail
        }
    }
} catch {
    $errorCount++
    $errorMessages += "Error cleaning PowerShell logs: $_"
}

# Clean PowerShell console history for all users
try {
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -notin @('Public', 'Default', 'All Users') }
    
    foreach ($profile in $userProfiles) {
        $userHistory = @(
            "$($profile.FullName)\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
            "$($profile.FullName)\AppData\Roaming\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt",
            "$($profile.FullName)\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\PSReadLineHistory.txt",
            "$($profile.FullName)\AppData\Roaming\Microsoft\PowerShell\PSReadLine\PSReadLineHistory.txt"
        )
        
        foreach ($historyFile in $userHistory) {
            if (Test-Path $historyFile) {
                Remove-Item -Force $historyFile -ErrorAction SilentlyContinue
            }
        }
    }
    
    # Clean current user's PowerShell history
    $currentUserHistory = @(
        "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
        "$env:APPDATA\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt",
        "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\PSReadLineHistory.txt",
        "$env:APPDATA\Microsoft\PowerShell\PSReadLine\PSReadLineHistory.txt"
    )
    
    foreach ($historyFile in $currentUserHistory) {
        if (Test-Path $historyFile) {
            Remove-Item -Force $historyFile -ErrorAction SilentlyContinue
        }
    }
} catch {
    $errorCount++
    $errorMessages += "Error cleaning PowerShell history: $_"
}

# Clean PowerShell module analysis cache
try {
    $moduleAnalysisCache = "$env:LOCALAPPDATA\Microsoft\Windows\PowerShell\ModuleAnalysisCache"
    if (Test-Path $moduleAnalysisCache) {
        Remove-Item -Force $moduleAnalysisCache -ErrorAction SilentlyContinue
    }
} catch {
    $errorCount++
    $errorMessages += "Error cleaning module cache: $_"
}

# Clean PowerShell transcript logs
try {
    $transcriptPaths = @(
        "$env:USERPROFILE\My Documents\PowerShell_transcript*.txt",
        "$env:USERPROFILE\Documents\PowerShell_transcript*.txt",
        "C:\Windows\Logs\PowerShell_transcript*.txt",
        "C:\Windows\Temp\PowerShell_transcript*.txt",
        "C:\Users\*\Documents\PowerShell_transcript*.txt",
        "C:\Users\*\My Documents\PowerShell_transcript*.txt"
    )
    
    foreach ($path in $transcriptPaths) {
        Get-ChildItem $path -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue
        }
    }
} catch {
    $errorCount++
    $errorMessages += "Error cleaning transcript logs: $_"
}

# Clean Windows Event Log files
try {
    $evtxFiles = Get-ChildItem "C:\Windows\System32\winevt\Logs\*.evtx" -ErrorAction SilentlyContinue
    if ($evtxFiles) {
        Stop-Service -Name EventLog -Force -ErrorAction SilentlyContinue
        foreach ($evtx in $evtxFiles) {
            try {
                Remove-Item -Force $evtx.FullName -ErrorAction SilentlyContinue
            } catch {
                # Silently fail for individual files
            }
        }
        Start-Service -Name EventLog -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
} catch {
    $errorCount++
    $errorMessages += "Error cleaning EVTX files: $_"
}

# Display summary
if ($errorCount -eq 0) {
    Write-OK "All event logs and PowerShell history cleared successfully"
} else {
    Write-Warn "Event log cleaning completed with $errorCount non-critical errors"
    if ($errorMessages.Count -gt 0) {
        Write-Host "  Error details (for debugging):" -ForegroundColor DarkGray
        foreach ($errMsg in $errorMessages) {
            Write-Host "    $errMsg" -ForegroundColor DarkGray
        }
    }
}

# Show disk space reclaimed (optional)
$freeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
Write-Host "  Current C: free space: ${freeAfter}GB" -ForegroundColor Gray

# =====================================================================
# STEP 18: FINAL VERIFICATION
# =====================================================================
Write-Step "18/19" "Final Verification"

Write-Host ""
Write-Host "  --- SYSTEM ---" -ForegroundColor White
Write-Host "  OS: $osVersion" -ForegroundColor Gray
Write-Host "  QEMU Guest Agent: $(if (Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue) { 'Installed' } else { 'Not Found' })" -ForegroundColor Gray
Write-Host "  VirtIO Drivers: Installed" -ForegroundColor Gray
Write-Host "  Hostname: $newHostname (overridden by Cloudbase-init on deploy)" -ForegroundColor Gray
Write-Host "  Timezone: $($tz.DisplayName)" -ForegroundColor Gray
Write-Host "  RDP: Enabled (NLA disabled)" -ForegroundColor Gray
Write-Host "  Power Plan: High Performance" -ForegroundColor Gray
Write-Host "  Hibernation: Disabled" -ForegroundColor Gray
Write-Host "  Pagefile: Disabled (auto per VM)" -ForegroundColor Gray
Write-Host ""

Write-Host "  --- USERS ---" -ForegroundColor White
$users = net user 2>&1
Write-Host "  $users" -ForegroundColor Gray
Write-Host ""

Write-Host "  --- CLOUDBASE-INIT ---" -ForegroundColor White
Write-Host "  Config: $(Test-Path "$cbConfPath\cloudbase-init.conf")" -ForegroundColor Gray
Write-Host "  Unattend Config: $(Test-Path "$cbConfPath\cloudbase-init-unattend.conf")" -ForegroundColor Gray
Write-Host "  Unattend.xml: $(Test-Path "$cbConfPath\Unattend.xml")" -ForegroundColor Gray
Write-Host "  SetPassword.ps1: $(Test-Path "$scriptDir\SetPassword.ps1")" -ForegroundColor Gray
Write-Host "  PasswordWatcher.ps1: $(Test-Path "$scriptDir\PasswordWatcher.ps1")" -ForegroundColor Gray
Write-Host "  HideCDROM.ps1: $(Test-Path "$scriptDir\HideCDROM.ps1")" -ForegroundColor Gray
Write-Host "  Service Account: LocalSystem" -ForegroundColor Gray
Write-Host ""

Write-Host "  --- SCHEDULED TASKS ---" -ForegroundColor White
$watchTask = Get-ScheduledTask -TaskName "CloudInit-PasswordWatcher" -ErrorAction SilentlyContinue
$hideTask = Get-ScheduledTask -TaskName "HideCloudInitCDROM" -ErrorAction SilentlyContinue
Write-Host "  PasswordWatcher (10s): $($watchTask.State)" -ForegroundColor Gray
Write-Host "  HideCDROM (startup): $($hideTask.State)" -ForegroundColor Gray
Write-Host ""

Write-Host "  --- PASSWORD POLICY ---" -ForegroundColor White
$maxPwAge = net accounts 2>&1 | Select-String "Maximum password age"
Write-Host "  $($maxPwAge.ToString().Trim())" -ForegroundColor Gray
Write-Host ""

Write-Host "  --- PARTITIONS ---" -ForegroundColor White
Get-Partition -DiskNumber 0 | ForEach-Object {
    Write-Host "  Partition $($_.PartitionNumber): $($_.Type) - $([math]::Round($_.Size/1GB, 2))GB" -ForegroundColor Gray
}
Write-Host ""

Write-Host "  --- DISK USAGE ---" -ForegroundColor White
$finalFree = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
$finalUsed = [math]::Round((Get-PSDrive C).Used / 1GB, 2)
Write-Host "  C: Used: ${finalUsed}GB / Free: ${finalFree}GB" -ForegroundColor Gray
Write-Host ""

# =====================================================================
# STEP 19: SYSPREP
# =====================================================================
Write-Step "19/19" "Sysprep"

try {
    Stop-Transcript -ErrorAction SilentlyContinue
} catch {
    # Transcript wasn't started or already stopped - ignore
}

# Clear current PowerShell session history
Clear-History

if ($SkipSysprep) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  PREPARATION COMPLETE (Sysprep skipped)" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Run Sysprep manually when ready:" -ForegroundColor White
    Write-Host '  cd "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"' -ForegroundColor Cyan
    Write-Host '  C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:Unattend.xml' -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  After VM shuts down, on Proxmox host:" -ForegroundColor White
    Write-Host "  qm set <VMID> --ide2 local-zfs:cloudinit" -ForegroundColor Cyan
    Write-Host "  qm set <VMID> --boot c --bootdisk scsi0" -ForegroundColor Cyan
    Write-Host "  qm template <VMID>" -ForegroundColor Cyan
    
    # Clear history one more time before exiting
    Clear-History
    exit
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  PREPARATION COMPLETE!" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  The VM will now Sysprep and SHUTDOWN automatically." -ForegroundColor White
Write-Host ""
Write-Host "  After VM shuts down, on Proxmox host run:" -ForegroundColor White
Write-Host "  qm set <VMID> --ide2 local-zfs:cloudinit" -ForegroundColor Cyan
Write-Host "  qm set <VMID> --boot c --bootdisk scsi0" -ForegroundColor Cyan
Write-Host "  qm template <VMID>" -ForegroundColor Cyan
Write-Host ""

$confirmSysprep = Read-Host "Run Sysprep now? (yes/no)"
if ($confirmSysprep -eq "yes") {
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    cd "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
    
    # Clear history before Sysprep
    Clear-History
    
    C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:Unattend.xml
} else {
    Write-Host ""
    Write-Host "Sysprep skipped. Run manually when ready:" -ForegroundColor Yellow
    Write-Host '  cd "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"' -ForegroundColor Cyan
    Write-Host '  C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:Unattend.xml' -ForegroundColor Cyan
    
    # Clear history before exiting
    Clear-History
}
