<#
.SYNOPSIS
    Updates VirtIO Windows drivers and QEMU Guest Agent from Fedora People Archive.
.DESCRIPTION
    This script runs on Windows and automates the update process for VirtIO components sourced from the Fedora People Archive root URL.
    It performs environment validation (OS and administrator rights), checks currently installed versions, resolves the latest available
    archive version, downloads the MSI package to a temporary working directory, installs it silently, writes structured logs, and
    optionally cleans up downloaded installer files.

    The script is designed to be PowerShell 5.1 and PowerShell 7 compatible.
    Use -Force, -AutoCleanup, and -AutoReboot for non-interactive / automated execution.
    Use -InstallVioSCSI to automatically install the vioscsi dummy device (e.g. from an RMM tool).

.PARAMETER Force
    Skips the initial confirmation prompt and runs non-interactively.

.PARAMETER AutoCleanup
    Automatically deletes downloaded MSI files after installation without prompting.

.PARAMETER AutoReboot
    Automatically reboots the system after installation if required (ExitCode 3010), without prompting.

.PARAMETER InstallVioSCSI
    Automatically installs the vioscsi dummy device without prompting.
    Use this switch when running from an RMM tool or other automated context.
    Has no effect if a vioscsi device is already present.

.PARAMETER VirtIOVersion
    Specify a particular VirtIO version to install (e.g. "0.1.285"). Default is "latest" which selects the newest available version from the manifest.

.PARAMETER QemuGAVersion
    Specify a particular QEMU Guest Agent version to install (e.g. "0.1.285"). Default is "latest" which selects the newest available version from the manifest.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1
    Runs the script interactively, downloads the latest VirtIO MSI, installs it, and prompts for cleanup.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot
    Fully automated run: no prompts, cleans up MSI files, reboots if needed. Skips vioscsi check.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot -InstallVioSCSI
    Fully automated run including vioscsi dummy device installation.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Update-VirtIO-QemuGA.ps1 -Force
    Executes the script from Windows PowerShell 5.1 in a controlled invocation context.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    None. The script writes status information to console and log file.

.NOTES
    ScriptName        : Update-VirtIO-QemuGA.ps1
    Version           : 2.0.0
    Author            : Frederik S. (fs1n)
    License           : MIT License
    GitHub            : fs1n/Update-VirtIO-QemuGA
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AutoCleanup,
    [switch]$AutoReboot,
    [switch]$InstallVioSCSI,
    [string]$VirtIOVersion  = "latest",
    [string]$QemuGAVersion  = "latest"
)

$ScriptVersion = "2.0.0"

#Regtion Environment Validation

if ($env:OS -ne "Windows_NT") {
    Write-Host "This script is only intended to run on Windows systems!" -ForegroundColor Red
    Write-Host "Current system: $($PSVersionTable.OS)" -ForegroundColor Yellow
    exit 1
}

# Check if running on x86_64 -> x64 for System Protection of installing wrong drivers
# Currently only x64 is supported by the script, so this is only a sanity check.
# Posts possibility for future feature to support arm64 etc. if this ever becomes relevant
# and if virtio-win and qemu-ga provide compatible drivers for those architectures.
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    Write-Host "This script is only intended to run on x86_64 (AMD64) Windows systems!" -ForegroundColor Red
    exit 1
}

# Check if script is run as administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run with administrator privileges!" -ForegroundColor Red
    exit 1
}

# Set TLS 1.2 if ran on PowerShell 5 (If Powershell 5 or lower)
if ($PSVersionTable.PSVersion.Major -le 5) {
    # Use bitwise OR to preserve any already-enabled protocols (e.g. TLS 1.3)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

#EndRegion

#Region Variables

$UninstallRegistryPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$VirtIODisplayNamePattern  = "*virtio*installer*"
$QemuGADisplayNamePattern  = "*QEMU Guest Agent*"
$VirtIOmsiFileName         = "virtio-win-gt-x64.msi"
$QemuGAmsiCandidates       = @(
    "qemu-ga-x86_64.msi",
    "qemu-ga-x64.msi"
)

$QemuGAExecutablePaths = @(
    'C:\Program Files\Qemu-ga\qemu-ga.exe',
    'C:\Program Files (x86)\Qemu-ga\qemu-ga.exe'
)

$ScriptTempDirName = "Qemu-VirtIO-Update-Temp"
$ScriptTempPath    = Join-Path -Path $env:TEMP -ChildPath $ScriptTempDirName

if (-not (Test-Path -Path $ScriptTempPath)) {
    New-Item -Path $ScriptTempPath -ItemType Directory | Out-Null
}

# Unique log file per run (timestamp in filename prevents log mixing across multiple daily runs)
# In Previouse verion it was daily based witch to me was enoying.
$script:LogFilePath    = Join-Path -Path $ScriptTempPath -ChildPath "log_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
$script:RebootRequired = $false

$MirrorBaseURL = "https://github.com/fs1n/Update-VirtIO-QemuGA/releases/download/mirror-latest"
$ManifestURL   = "$MirrorBaseURL/manifest.json"

#EndRegion

#Region Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes log messages to a file with timestamp and severity level.
    .DESCRIPTION
        Logs script events with Info, Warning, or Error levels using European date/time format (dd.MM.yyyy HH:mm:ss).
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The severity level: Info, Warning, or Error. Default is Info.
    .EXAMPLE
        Write-Log -Message "Script started" -Level Info
        Write-Log -Message "Configuration file not found" -Level Warning
        Write-Log -Message "Database connection failed" -Level Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
    $logEntry  = "$timestamp [$Level] $Message"

    if (-not (Test-Path -Path $script:LogFilePath)) {
        New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
        Add-Content -Path $script:LogFilePath -Value "=== Log initialized on $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') ==="
    }

    Add-Content -Path $script:LogFilePath -Value $logEntry

    switch ($Level) {
        "Info"    { Write-Host $logEntry -ForegroundColor Green }
        "Warning" { Write-Host $logEntry -ForegroundColor Yellow }
        "Error"   { Write-Host $logEntry -ForegroundColor Red }
    }
}

Function Read-YesNoChoice {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$false)][String]$Title = "",
        [Parameter(Mandatory=$true)][String]$Message,
        [Parameter(Mandatory=$false)][Int]$DefaultOption = 0
    )
    $No = New-Object System.Management.Automation.Host.ChoiceDescription '&No', 'No'
    $Yes = New-Object System.Management.Automation.Host.ChoiceDescription '&Yes', 'Yes'
    $Options = [System.Management.Automation.Host.ChoiceDescription[]]($No, $Yes)
    return $host.ui.PromptForChoice($Title, $Message, $Options, $DefaultOption)
}

function Test-PendingReboot {
# Based on https://stackoverflow.com/questions/47867949/how-can-i-check-for-a-pending-reboot
    $pending = $false
    $checks = @(
        @{Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; Value = 'RebootPending'; Type = 'Key'},
        @{Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; Value = 'RebootInProgress'; Type = 'Value'},
        @{Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; Value = 'PackagesPending'; Type = 'Value'},
        @{Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Value = 'PendingFileRenameOperations'; Type = 'Value'},
        @{Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Value = 'PendingFileRenameOperations2'; Type = 'Value'},
        @{Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'; Value = 'RebootRequired'; Type = 'Key'}
    )

    foreach ($check in $checks) {
        if ($check.Type -eq 'Key') {
            if (Test-Path $check.Path) {
                $pending = $true
                Write-Log -Message "Pending reboot marker detected: $($check.Path) exists" -Level "Warning"
            }
        } else {
            try {
                Get-ItemProperty -Path $check.Path -Name $check.Value -ErrorAction Stop | Out-Null
                $pending = $true
                Write-Log -Message "Pending reboot marker detected: $($check.Path)\$($check.Value) exists" -Level "Warning"
            } catch {}
        }
    }

    return $pending
}

function Get-VirtIOComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionString
    )

    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }

    # Strip optional "-<Release>" suffix (e.g. "0.1.285-1" -> "0.1.285") before comparing.
    # The Windows installer only reports the Core version, so comparing Core vs. Core is correct.
    $normalized = $VersionString.Trim() -replace '-\d+$', ''
    $match = [regex]::Match($normalized, '^(?<Core>\d+(?:\.\d+){1,3})$')
    if (-not $match.Success) { return $null }

    return [version]$match.Groups['Core'].Value
}

function Install-MsiPackage {
    <#
    .SYNOPSIS
        Downloads, installs, and optionally cleans up an MSI package.
    .PARAMETER DisplayName
        Human-readable name used in log messages (e.g. "VirtIO" or "QEMU Guest Agent").
    .PARAMETER MsiFileName
        Filename of the MSI (e.g. "virtio-win-gt-x64.msi").
    .PARAMETER DownloadURL
        Full URL to download the MSI from.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$MsiFileName,

        [Parameter(Mandatory = $true)]
        [string]$DownloadURL
    )

    $localPath = Join-Path -Path $ScriptTempPath -ChildPath $MsiFileName

    # --- Download ---
    Write-Log -Message "$DisplayName download URL: $DownloadURL" -Level "Info"
    Write-Log -Message "Starting $DisplayName download to: $ScriptTempPath" -Level "Info"
    try {
        Invoke-WebRequest -Uri $DownloadURL -OutFile $localPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message "Successfully downloaded $MsiFileName" -Level "Info"
    }
    catch {
        Write-Log -Message "Failed to download $MsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    # --- Install ---
    Write-Log -Message "Starting installation of $MsiFileName" -Level "Info"
    try {
        $installProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$localPath`" /qn /norestart" -Wait -PassThru -ErrorAction Stop
        if ($installProcess.ExitCode -in 0, 3010) {
            Write-Log -Message "Successfully installed $MsiFileName" -Level "Info"
            if ($installProcess.ExitCode -eq 3010) {
                $script:RebootRequired = $true
                Write-Log -Message "$DisplayName installation requires a reboot (ExitCode 3010)." -Level "Warning"
            }
        }
        else {
            Write-Log -Message "Installation of $MsiFileName failed with exit code $($installProcess.ExitCode)" -Level "Error"
            exit 1
        }

        if (Test-PendingReboot) {
            $script:RebootRequired = $true
            Write-Log -Message "$DisplayName installation left the system in a pending reboot state." -Level "Warning"
        }
    }
    catch {
        Write-Log -Message "Failed to install $MsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    # --- Cleanup ---
    $doCleanup = $AutoCleanup
    if (-not $doCleanup) {
        $cleanupAnswer = Read-YesNoChoice -Message "Should the downloaded MSI file be deleted?" -DefaultOption 1
        $doCleanup = $cleanupAnswer -match 1
    }

    if ($doCleanup) {
        try {
            Remove-Item -Path $localPath -Force -ErrorAction Stop
            Write-Log -Message "Deleted downloaded MSI file: $localPath" -Level "Info"
        }
        catch {
            Write-Log -Message "Failed to delete downloaded MSI file: $localPath. Error: $_" -Level "Warning"
        }
    }
    else {
        Write-Log -Message "Downloaded MSI file retained at: $localPath" -Level "Info"
    }
}

function Read-VersionChoice {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("VirtIO","QEMU Guest Agent")]
        [string]$ComponentName,

        [Parameter(Mandatory = $true)]
        [array]$Versions
    )

    if (-not $Versions -or $Versions.Count -eq 0) {
        Write-Log -Message "No available versions found for $ComponentName." -Level "Error"
        throw "No available versions found for $ComponentName."
    }

    Write-Host "`nAvailable $ComponentName versions:" -ForegroundColor Cyan

    for ($i = 0; $i -lt $Versions.Count; $i++) {
        $tag = if ($i -eq 0) { " (latest)" } else { "" }
        Write-Host "  [$($i + 1)] $($Versions[$i].version)$tag"
    }
    do {
        $choice = Read-Host "Select version [1-$($Versions.Count)]"
    } while ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $Versions.Count)
    return $Versions[[int]$choice - 1]
}

#EndRegion

#Region Script

Write-Log -Message "=== Update-VirtIO-QemuGA.ps1 v$ScriptVersion started ===" -Level "Info"

if (-not $Force) {
    $confirm = Read-YesNoChoice -Message "Should the VirtIO drivers and the QEMU Guest Agent be updated?" -DefaultOption 0
    if ($confirm -notmatch 1) {
        Write-Host "Script canceled." -ForegroundColor Yellow
        exit 0
    }
}

$SkipVirtIO = $false
$SkipQemuGA = $false

# --- Detect installed VirtIO version (Registry) ---
try {
    $VirtIOCurrentVersion = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like $VirtIODisplayNamePattern } |
        Select-Object -ExpandProperty DisplayVersion -First 1

    if ([string]::IsNullOrWhiteSpace($VirtIOCurrentVersion)) {
        Write-Log -Message "VirtIO not installed (no matching registry entry found)." -Level "Warning"
    }
    else {
        Write-Log -Message "Detected VirtIO version: $VirtIOCurrentVersion" -Level "Info"
    }
}
catch {
    Write-Log -Message "Unable to retrieve VirtIO version: $_" -Level "Warning"
}

# --- Detect installed QEMU Guest Agent version (Registry preferred, executable fallback) ---
try {
    $QemuGACurrentVersion = $null

    # Primary: Registry lookup (consistent with VirtIO detection)
    $QemuGACurrentVersion = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like $QemuGADisplayNamePattern } |
        Select-Object -ExpandProperty DisplayVersion -First 1

    # Fallback: executable file version
    if ([string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
        foreach ($path in $QemuGAExecutablePaths) {
            if (Test-Path -Path $path) {
                $QemuGACurrentVersion = (Get-Item -Path $path -ErrorAction Stop).VersionInfo.FileVersion
                Write-Log -Message "QEMU Guest Agent version resolved via executable fallback." -Level "Info"
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
        Write-Log -Message "QEMU Guest Agent not installed (no registry entry or executable found)." -Level "Warning"
    }
    else {
        Write-Log -Message "Detected QEMU Guest Agent version: $QemuGACurrentVersion" -Level "Info"
    }
}
catch {
    Write-Log -Message "Unable to retrieve QEMU Guest Agent version: $_" -Level "Warning"
}

# --- Fetch release manifest ---
Write-Log -Message "Fetching release manifest from: $ManifestURL" -Level "Info"
try {
    $manifestJson = Invoke-WebRequest -Uri $ManifestURL -UseBasicParsing -ErrorAction Stop
    $manifest = $manifestJson.Content | ConvertFrom-Json
}
catch {
    Write-Log -Message "Failed to fetch release manifest. Error: $_" -Level "Error"
    exit 1
}

# --- Resolve VirtIO version ---
if ($VirtIOVersion -eq "latest") {
    $selectedVirtIO = $manifest.virtio[0]
    if (-not $Force) {
        Write-Host "`nLatest available VirtIO: $($selectedVirtIO.version)" -ForegroundColor Cyan
        $ans = Read-YesNoChoice -Message "Install this version? (Y to confirm, N to pick from list)" -DefaultOption 1
        if ($ans -notmatch 1) {
            $selectedVirtIO = Read-VersionChoice -ComponentName "VirtIO" -Versions $manifest.virtio
        }
    }
}
else {
    $selectedVirtIO = $manifest.virtio | Where-Object { $_.version -eq $VirtIOVersion } | Select-Object -First 1
    if (-not $selectedVirtIO) {
        Write-Log -Message "VirtIO version '$VirtIOVersion' not found in mirror release. Available: $(($manifest.virtio | ForEach-Object { $_.version }) -join ', ')" -Level "Error"
        exit 1
    }
}
Write-Log -Message "Selected VirtIO version: $($selectedVirtIO.version)" -Level "Info"

# --- Resolve QEMU-GA version ---
if ($QemuGAVersion -eq "latest") {
    $selectedQemuGA = $manifest.qemu_ga[0]
    if (-not $Force) {
        Write-Host "`nLatest available QEMU Guest Agent: $($selectedQemuGA.version)" -ForegroundColor Cyan
        $ans = Read-YesNoChoice -Message "Install this version? (Y to confirm, N to pick from list)" -DefaultOption 1
        if ($ans -notmatch 1) {
            $selectedQemuGA = Read-VersionChoice -ComponentName "QEMU Guest Agent" -Versions $manifest.qemu_ga
        }
    }
}
else {
    $selectedQemuGA = $manifest.qemu_ga | Where-Object { $_.version -eq $QemuGAVersion } | Select-Object -First 1
    if (-not $selectedQemuGA) {
        Write-Log -Message "QEMU-GA version '$QemuGAVersion' not found in mirror release. Available: $(($manifest.qemu_ga | ForEach-Object { $_.version }) -join ', ')" -Level "Error"
        exit 1
    }
}
Write-Log -Message "Selected QEMU-GA version: $($selectedQemuGA.version)" -Level "Info"

# --- VirtIO: version comparison + install ---
if (-not [string]::IsNullOrWhiteSpace($VirtIOCurrentVersion)) {
    $installedVer = Get-VirtIOComparableVersion -VersionString $VirtIOCurrentVersion
    $availableVer = Get-VirtIOComparableVersion -VersionString $selectedVirtIO.version
    if ($null -ne $installedVer -and $null -ne $availableVer -and $installedVer -ge $availableVer) {
        Write-Log -Message "VirtIO is already up-to-date (installed: $VirtIOCurrentVersion). Skipping." -Level "Info"
        $SkipVirtIO = $true
    }
}

if (-not $SkipVirtIO) {
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($selectedVirtIO.file)
    $assetName = "${stem}_$($selectedVirtIO.version).msi"
    $url       = "$MirrorBaseURL/$assetName"
    Install-MsiPackage -DisplayName "VirtIO" -MsiFileName $selectedVirtIO.file -DownloadURL $url
}

# --- QEMU-GA: version comparison + install ---
if (-not [string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
    $installedVer = Get-VirtIOComparableVersion -VersionString $QemuGACurrentVersion
    $availableVer = Get-VirtIOComparableVersion -VersionString $selectedQemuGA.version
    if ($null -ne $installedVer -and $null -ne $availableVer -and $installedVer -ge $availableVer) {
        Write-Log -Message "QEMU Guest Agent is already up-to-date (installed: $QemuGACurrentVersion). Skipping." -Level "Info"
        $SkipQemuGA = $true
    }
}

if (-not $SkipQemuGA) {
    $stem      = [System.IO.Path]::GetFileNameWithoutExtension($selectedQemuGA.file)
    $assetName = "${stem}_$($selectedQemuGA.version).msi"
    $url       = "$MirrorBaseURL/$assetName"
    Install-MsiPackage -DisplayName "QEMU Guest Agent" -MsiFileName $selectedQemuGA.file -DownloadURL $url
}



# --- Reboot handling ---
if ($script:RebootRequired) {

    Write-Log -Message "At least one installation requires a system reboot." -Level "Warning"

    $doReboot = $AutoReboot
    if (-not $doReboot) {
        $restartAnswer = Read-YesNoChoice -Message "A reboot is required to finalize installation. Restart now? (y/N)" -DefaultOption 0
        $doReboot = $restartAnswer -match 1
    }

    if ($doReboot) {
        Write-Log -Message "Initiating system reboot." -Level "Warning"
        try {
            Restart-Computer -Force
        }
        catch {
            Write-Log -Message "Failed to trigger system reboot. Error: $_" -Level "Error"
            exit 1
        }
    }
    else {
        Write-Log -Message "Reboot postponed. Please reboot later to complete installation." -Level "Warning"
    }
}

# --- vioscsi dummy device check (Proxmox VE migration preparation) ---
if (-not (Get-PnpDevice | Where-Object { $_.Service -eq "vioscsi" })) {
    # Determine whether to install: honour -InstallVioSCSI switch, otherwise prompt (unless -Force suppresses all prompts)
    $doInstallVioSCSI = $InstallVioSCSI.IsPresent
    if (-not $Force -and -not $doInstallVioSCSI) {
        Write-Host "No vioscsi device found. If you want to migrate to Proxmox VE you need to pre-install a dummy vioscsi device to make migration seamless." -ForegroundColor Yellow
        Write-Host "To install the dummy vioscsi device, an external script will be downloaded and executed from GitHub. The script is open source and available at:" -ForegroundColor Red
        Write-Host "https://github.com/croit/load-virtio-scsi-on-boot" -ForegroundColor Red
        $confirmVioSCSI   = Read-YesNoChoice -Message "Do you want to install a dummy vioscsi device now? (y/N)" -DefaultOption 0
        $doInstallVioSCSI = $confirmVioSCSI -match 1
    }

    if ($doInstallVioSCSI) {
        # Credit: vioscsi dummy device installer by croit
        # https://github.com/croit/load-virtio-scsi-on-boot (MIT License)
        $dummyInstallerURL = "https://raw.githubusercontent.com/croit/load-virtio-scsi-on-boot/refs/heads/main/enable-vioscsi-to-load-on-boot.ps1"
        $dummyScriptPath   = Join-Path -Path $ScriptTempPath -ChildPath "enable-vioscsi-to-load-on-boot.ps1"

        Write-Log -Message "Downloading vioscsi dummy installer to: $dummyScriptPath" -Level "Info"
        
        try {
            Invoke-WebRequest -Uri $dummyInstallerURL -OutFile $dummyScriptPath -UseBasicParsing -ErrorAction Stop
            Write-Log -Message "Successfully downloaded vioscsi dummy installer." -Level "Info"
        }
        catch {
            Write-Log -Message "Failed to download vioscsi dummy installer. Error: $_" -Level "Error"
            exit 1
        }

        Write-Log -Message "Executing vioscsi dummy installer." -Level "Info"
        try {
            $shell = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh.exe" } else { "powershell.exe" }
            & $shell -ExecutionPolicy Bypass -File $dummyScriptPath
            
            # Clean up downloaded script after successful execution
            Remove-Item -Path $dummyScriptPath -Force -ErrorAction SilentlyContinue
            Write-Log -Message "Deleted vioscsi dummy installer Script: $dummyScriptPath" -Level "Info"
        }
        catch {
            Write-Log -Message "Failed to execute vioscsi dummy installer. Error: $_" -Level "Error"
            exit 1
        }
    }
    else {
        Write-Log -Message "vioscsi device not found. Skipping dummy device installation." -Level "Info"
    }
}
else {
    Write-Host "vioscsi device found. No need to install a dummy vioscsi device." -ForegroundColor Green
}

Write-Log -Message "=== Script completed ===" -Level "Info"

#EndRegion