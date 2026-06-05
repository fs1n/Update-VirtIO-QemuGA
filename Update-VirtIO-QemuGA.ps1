<#
.SYNOPSIS
    Updates VirtIO Windows drivers and QEMU Guest Agent from the project's release manifest.
.DESCRIPTION
    This script runs on Windows and automates the update process for the VirtIO drivers and the QEMU Guest Agent.
    It performs environment validation (OS and administrator rights), checks currently installed versions, resolves
    the desired version from a release manifest (manifest.json in this repository), downloads the MSI package to a
    temporary working directory, installs it silently, writes structured logs, and optionally cleans up downloaded
    installer files.

    The script is designed to be PowerShell 5.1 and PowerShell 7 compatible.
    Use -Force, -AutoCleanup, and -AutoReboot for non-interactive / automated execution.
    Use -InstallVioSCSI to automatically install the vioscsi dummy device (e.g. from an RMM tool).

.PARAMETER Force
    Skips ALL interactive prompts and runs non-interactively. Use this for fully automated / RMM-driven runs.

.PARAMETER AutoCleanup
    Automatically deletes downloaded MSI files after installation without prompting.
    Implicitly enabled when -Force is used.

.PARAMETER AutoReboot
    Automatically reboots the system after installation if required (ExitCode 3010), without prompting.
    Implicitly enabled when -Force is used.

.PARAMETER InstallVioSCSI
    Automatically installs the vioscsi dummy device without prompting.
    Use this switch when running from an RMM tool or other automated context.
    Has no effect if a vioscsi device is already present.

.PARAMETER VirtIOVersion
    Specify a particular VirtIO version to install (e.g. "0.1.285-1"). The value must match a manifest entry
    exactly (the Windows installer reports the core version, e.g. "0.1.285", while the manifest typically
    includes the package release suffix, e.g. "0.1.285-1"). Use "latest" (the default) to select the newest
    available version from the manifest.

.PARAMETER QemuGAVersion
    Specify a particular QEMU Guest Agent version to install (e.g. "110.0.2-1"). The value must match a
    manifest entry exactly. Use "latest" (the default) to select the newest available version from the manifest.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1
    Runs the script interactively, downloads the latest VirtIO and QEMU-GA MSIs, installs them, and prompts for cleanup.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot
    Fully automated run: no prompts, cleans up MSI files, reboots if needed. Skips vioscsi check.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot -InstallVioSCSI
    Fully automated run including vioscsi dummy device installation.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1 -VirtIOVersion "0.1.285-1" -QemuGAVersion "110.0.2-1"
    Pins both components to specific manifest versions. No prompts.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Update-VirtIO-QemuGA.ps1 -Force
    Executes the script from Windows PowerShell 5.1 in a controlled invocation context.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    None. The script writes status information to console and log file.

.NOTES
    ScriptName  : Update-VirtIO-QemuGA.ps1
    Version     : 2.1.1
    Author      : Frederik S. (fs1n)
    License     : MIT License
    GitHub      : fs1n/Update-VirtIO-QemuGA
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AutoCleanup,
    [switch]$AutoReboot,
    [switch]$InstallVioSCSI,
    [ValidatePattern('^(latest|\d+(?:\.\d+){1,3}(?:-\d+)?)$')]
    [string]$VirtIOVersion  = "latest",
    [ValidatePattern('^(latest|\d+(?:\.\d+){1,3}(?:-\d+)?)$')]
    [string]$QemuGAVersion  = "latest"
)

# Single source of truth for the script's own version. Mirrors the .NOTES block above.
$ScriptVersion = "2.0.0"

#Region Environment Validation

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

$QemuGAExecutablePaths = @(
    'C:\Program Files\Qemu-ga\qemu-ga.exe',
    'C:\Program Files (x86)\Qemu-ga\qemu-ga.exe'
)

$ScriptTempDirName = "Qemu-VirtIO-Update-Temp"
$ScriptTempPath    = Join-Path -Path $env:TEMP -ChildPath $ScriptTempDirName

if (-not (Test-Path -Path $ScriptTempPath)) {
    New-Item -Path $ScriptTempPath -ItemType Directory | Out-Null
}

# Unique log file per run: the timestamp in the filename keeps multiple daily runs from
# sharing a log file, which previously made correlating entries from a single run awkward.
$script:LogFilePath    = Join-Path -Path $ScriptTempPath -ChildPath "log_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
$script:RebootRequired = $false

$ManifestURL = "https://raw.githubusercontent.com/fs1n/Update-VirtIO-QemuGA/refs/heads/main/manifest.json"

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

# Build a consistent, loggable error context record from a catch block.
# Returns a PSCustomObject so callers can re-throw with full context preserved.
function Get-ErrorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Caller,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null
    )

    if ($null -eq $ErrorRecord) { $ErrorRecord = $_ }

    $message = if ($ErrorRecord -and $ErrorRecord.Exception) {
        $ErrorRecord.Exception.Message
    } else {
        "$ErrorRecord"
    }

    $full = "[$Caller] $message"
    if ($ErrorRecord -and $ErrorRecord.ScriptStackTrace) {
        $full += "`n$($ErrorRecord.ScriptStackTrace)"
    }
    return $full
}

function Read-YesNoChoice {
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
    [CmdletBinding()]
    param()
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

function Get-ComparableVersion {
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
    .DESCRIPTION
        Pulls the MSI from the manifest URL into the script's temp directory, runs msiexec in quiet mode,
        records a reboot-required flag on ExitCode 3010, and finally cleans up the downloaded file
        according to -AutoCleanup (or -Force, which implies it).
    .PARAMETER DisplayName
        Human-readable name used in log messages (e.g. "VirtIO" or "QEMU Guest Agent").
    .PARAMETER MsiFileName
        Filename to save the MSI as on disk. The actual value is taken from the manifest entry's "file"
        field, so this parameter should normally be passed straight through from there.
    .PARAMETER DownloadURL
        Full URL to download the MSI from. Taken from the manifest entry's "url" field.
    .OUTPUTS
        None. Throws on any unrecoverable download or install failure so the caller can decide how
        to react (top-level script exits with a non-zero status).
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
        $ctx = Get-ErrorContext -Caller "Install-MsiPackage (download $DisplayName)"
        Write-Log -Message "Failed to download $MsiFileName. $ctx" -Level "Error"
        throw
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
            throw "msiexec exited with code $($installProcess.ExitCode) for $MsiFileName"
        }

        if (Test-PendingReboot) {
            $script:RebootRequired = $true
            Write-Log -Message "$DisplayName installation left the system in a pending reboot state." -Level "Warning"
        }
    }
    catch {
        $ctx = Get-ErrorContext -Caller "Install-MsiPackage (install $DisplayName)"
        Write-Log -Message "Failed to install $MsiFileName. $ctx" -Level "Error"
        throw
    }

    # --- Cleanup ---
    # -Force implies -AutoCleanup so non-interactive runs never leave installers behind.
    $doCleanup = $AutoCleanup -or $Force
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
            $ctx = Get-ErrorContext -Caller "Install-MsiPackage (cleanup $DisplayName)"
            Write-Log -Message "Failed to delete downloaded MSI file: $localPath. $ctx" -Level "Warning"
        }
    }
    else {
        Write-Log -Message "Downloaded MSI file retained at: $localPath" -Level "Info"
    }
}

function Read-VersionChoice {
    [CmdletBinding()]
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

function Resolve-AndInstallComponent {
    <#
    .SYNOPSIS
        Resolves a version from the manifest for one component (VirtIO or QEMU-GA), compares it
        against the locally installed version, and triggers the install if an upgrade is needed.
    .DESCRIPTION
        This is the single source of truth for the "pick a version -> compare -> install" flow
        that used to be duplicated for VirtIO and QEMU Guest Agent. Both components share the
        exact same logic, differing only in their display name, manifest key, requested version
        and currently installed version. Non-interactive callers (those passing -Force) skip the
        "install latest?" prompt and go straight to installation.
    .PARAMETER ComponentName
        Human-readable name used in log/console messages (e.g. "VirtIO" or "QEMU Guest Agent").
    .PARAMETER ManifestKey
        Property name on the manifest object (e.g. "virtio" or "qemu_ga").
    .PARAMETER RequestedVersion
        Value from the corresponding -VirtIOVersion / -QemuGAVersion script parameter. Either
        "latest" (or empty) to pick the newest entry, or an exact manifest version string.
    .PARAMETER InstalledVersion
        The version currently installed on the local system, or $null / empty if the component
        is not installed. Used to skip the install when already up-to-date.
    .OUTPUTS
        None. Throws if the manifest key is missing, the requested version is unknown, or the
        install itself fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("VirtIO", "QEMU Guest Agent")]
        [string]$ComponentName,

        [Parameter(Mandatory = $true)]
        [string]$ManifestKey,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RequestedVersion = "latest",

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstalledVersion = $null
    )

    $availableVersions = $manifest.$ManifestKey
    if (-not $availableVersions -or $availableVersions.Count -eq 0) {
        throw "Manifest has no entries under '$ManifestKey' for $ComponentName."
    }

    # --- Version selection ---
    $useLatest = [string]::IsNullOrWhiteSpace($RequestedVersion) -or $RequestedVersion -eq "latest"
    if ($useLatest) {
        $selected = $availableVersions[0]
    }
    else {
        $selected = $availableVersions | Where-Object { $_.version -eq $RequestedVersion } | Select-Object -First 1
        if (-not $selected) {
            $availableList = ($availableVersions | ForEach-Object { $_.version }) -join ', '
            throw "$ComponentName version '$RequestedVersion' not found in manifest. Available: $availableList"
        }
    }
    Write-Log -Message "Selected $ComponentName version: $($selected.version)" -Level "Info"

    # --- Up-to-date check (runs BEFORE the install prompt so we never ask
    # the user to install something they already have). Get-ComparableVersion
    # strips any "-<Release>" suffix, so e.g. installed "0.1.285" is correctly
    # recognised as equal to manifest "0.1.285-1". ---
    if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
        $installedComparable = Get-ComparableVersion -VersionString $InstalledVersion
        $availableComparable = Get-ComparableVersion -VersionString $selected.version
        if ($null -ne $installedComparable -and $null -ne $availableComparable -and $installedComparable -ge $availableComparable) {
            Write-Log -Message "$ComponentName is already up-to-date (installed: $InstalledVersion, manifest: $($selected.version)). Skipping." -Level "Info"
            return
        }
    }

    # --- Interactive "install latest?" prompt (only reached if an upgrade is actually available) ---
    if ($useLatest -and -not $Force) {
        Write-Host "`nLatest available $ComponentName`: $($selected.version)" -ForegroundColor Cyan
        $ans = Read-YesNoChoice -Message "Install this version? (Y to confirm, N to pick from list)" -DefaultOption 1
        if ($ans -notmatch 1) {
            $selected = Read-VersionChoice -ComponentName $ComponentName -Versions $availableVersions
            # Re-run the up-to-date check against the newly picked version so a
            # user who picks an already-installed version from the list also
            # gets the skip behaviour.
            if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
                $installedComparable = Get-ComparableVersion -VersionString $InstalledVersion
                $availableComparable = Get-ComparableVersion -VersionString $selected.version
                if ($null -ne $installedComparable -and $null -ne $availableComparable -and $installedComparable -ge $availableComparable) {
                    Write-Log -Message "$ComponentName is already up-to-date (installed: $InstalledVersion, picked: $($selected.version)). Skipping." -Level "Info"
                    return
                }
            }
            Write-Log -Message "Selected $ComponentName version: $($selected.version)" -Level "Info"
        }
    }

    # --- Install ---
    Install-MsiPackage -DisplayName $ComponentName -MsiFileName $selected.file -DownloadURL $selected.url
}

#EndRegion

#Region Script

# Top-level entrypoint. We wrap the entire main flow in a try/catch so any exception raised
# by a helper (which now uses `throw` instead of `exit 1`) is logged exactly once and the
# script exits with a non-zero status. This keeps the process exit decision in one place.
function Invoke-Main {
    [CmdletBinding()]
    param()

    Write-Log -Message "=== Update-VirtIO-QemuGA.ps1 v$ScriptVersion started ===" -Level "Info"

    if (-not $Force) {
        $confirm = Read-YesNoChoice -Message "Should the VirtIO drivers and the QEMU Guest Agent be updated?" -DefaultOption 0
        if ($confirm -notmatch 1) {
            Write-Host "Script canceled." -ForegroundColor Yellow
            return
        }
    }

    # --- Detect installed VirtIO version (Registry) ---
    $VirtIOCurrentVersion = $null
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
        $ctx = Get-ErrorContext -Caller "VirtIO version detection"
        Write-Log -Message "Unable to retrieve VirtIO version. $ctx" -Level "Warning"
    }

    # --- Detect installed QEMU Guest Agent version (Registry preferred, executable fallback) ---
    $QemuGACurrentVersion = $null
    try {
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
        $ctx = Get-ErrorContext -Caller "QEMU-GA version detection"
        Write-Log -Message "Unable to retrieve QEMU Guest Agent version. $ctx" -Level "Warning"
    }

    # --- Fetch release manifest ---
    Write-Log -Message "Fetching release manifest from: $ManifestURL" -Level "Info"
    $manifest = $null
    try {
        $manifestJson = Invoke-WebRequest -Uri $ManifestURL -UseBasicParsing -ErrorAction Stop
        $manifest     = $manifestJson.Content | ConvertFrom-Json
    }
    catch {
        $ctx = Get-ErrorContext -Caller "Manifest fetch"
        Write-Log -Message "Failed to fetch release manifest. $ctx" -Level "Error"
        throw
    }

    # --- Resolve + install each component through the shared helper ---
    Resolve-AndInstallComponent -ComponentName "VirtIO"           -ManifestKey "virtio"   -RequestedVersion $VirtIOVersion -InstalledVersion $VirtIOCurrentVersion
    Resolve-AndInstallComponent -ComponentName "QEMU Guest Agent" -ManifestKey "qemu_ga"  -RequestedVersion $QemuGAVersion -InstalledVersion $QemuGACurrentVersion

    # --- Reboot handling ---
    if ($script:RebootRequired) {
        Write-Log -Message "At least one installation requires a system reboot." -Level "Warning"

        # -Force implies -AutoReboot so non-interactive runs honour the pending reboot.
        $doReboot = $AutoReboot -or $Force
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
                $ctx = Get-ErrorContext -Caller "Restart-Computer"
                Write-Log -Message "Failed to trigger system reboot. $ctx" -Level "Error"
                throw
            }
        }
        else {
            Write-Log -Message "Reboot postponed. Please reboot later to complete installation." -Level "Warning"
        }
    }

    # --- vioscsi dummy device check (Proxmox VE migration preparation) ---
    if (-not (Get-PnpDevice | Where-Object { $_.Service -eq "vioscsi" })) {
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
                $ctx = Get-ErrorContext -Caller "vioscsi installer download"
                Write-Log -Message "Failed to download vioscsi dummy installer. $ctx" -Level "Error"
                throw
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
                $ctx = Get-ErrorContext -Caller "vioscsi installer execute"
                Write-Log -Message "Failed to execute vioscsi dummy installer. $ctx" -Level "Error"
                throw
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
}

# Run main, then decide the exit code in exactly one place.
try {
    Invoke-Main
    exit 0
}
catch {
    # Anything that escaped from a helper ends up here. Log the full context and bail.
    $ctx = Get-ErrorContext -Caller "Top-level"
    Write-Log -Message "Script aborted. $ctx" -Level "Error"
    exit 1
}

#EndRegion