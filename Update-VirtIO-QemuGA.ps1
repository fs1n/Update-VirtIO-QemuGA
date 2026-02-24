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
    Version           : 0.2.4
    Author            : Frederik S. (fs1n)
    License           : MIT License

.LINK
    TO_BE_REPLACED_DOCUMENTATION_URL
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AutoCleanup,
    [switch]$AutoReboot,
    [switch]$InstallVioSCSI
)

$ScriptVersion = "0.2.4"

if ($env:OS -ne "Windows_NT") {
    Write-Host "This script is only intended to run on Windows systems!" -ForegroundColor Red
    Write-Host "Current system: $($PSVersionTable.OS)" -ForegroundColor Yellow
    exit 1
}

# Check if run as administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run with administrator privileges!" -ForegroundColor Red
    exit 1
}

if ($PSVersionTable.PSVersion.Major -le 5) {
    # Use bitwise OR to preserve any already-enabled protocols (e.g. TLS 1.3)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

#Region Variables

# FPA is used as the alias for Fedora People Archive in the script
$FPARootURL        = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads"
$ArchiveVirtIOURL  = "$FPARootURL/archive-virtio/"
$ArchiveQemuGAURL  = "$FPARootURL/archive-qemu-ga/"

$UninstallRegistryPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$VirtIODisplayNamePattern  = "*virtio*installer*"
$QemuGADisplayNamePattern  = "*QEMU Guest Agent*"
$VirtIOmsiFileName         = "virtio-win-gt-x64.msi"
$QemuGAFolderPattern       = '^qemu-ga-win-(?<Core>\d+(?:\.\d+){0,3})-(?<Release>\d+)(?:\.(?<Dist>[^/]+))?/?$'
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
$script:LogFilePath    = Join-Path -Path $ScriptTempPath -ChildPath "log_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
$script:RebootRequired = $false

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

function Get-QemuGAFolderMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Href
    )

    $match = [regex]::Match($Href, $QemuGAFolderPattern)
    if (-not $match.Success) { return $null }

    $coreRaw   = $match.Groups['Core'].Value
    $coreParts = $coreRaw.Split('.')
    $core1 = 0; $core2 = 0; $core3 = 0; $core4 = 0

    if ($coreParts.Count -ge 1) { $core1 = [int]$coreParts[0] }
    if ($coreParts.Count -ge 2) { $core2 = [int]$coreParts[1] }
    if ($coreParts.Count -ge 3) { $core3 = [int]$coreParts[2] }
    if ($coreParts.Count -ge 4) { $core4 = [int]$coreParts[3] }

    $release   = [int]$match.Groups['Release'].Value
    $distRaw   = $match.Groups['Dist'].Value
    $distMajor = 0
    $distMinor = 0

    if (-not [string]::IsNullOrWhiteSpace($distRaw)) {
        $distMatch = [regex]::Match($distRaw, 'el(?<major>\d+)(?:_(?<minor>\d+))?')
        if ($distMatch.Success) {
            $distMajor = [int]$distMatch.Groups['major'].Value
            if ($distMatch.Groups['minor'].Success) {
                $distMinor = [int]$distMatch.Groups['minor'].Value
            }
        }
    }

    [PSCustomObject]@{
        Href      = $Href
        Core      = $coreRaw
        Release   = $release
        Dist      = $distRaw
        SortCore1 = $core1
        SortCore2 = $core2
        SortCore3 = $core3
        SortCore4 = $core4
        DistMajor = $distMajor
        DistMinor = $distMinor
    }
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

function Get-QemuGALocalComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionString
    )

    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }

    $normalized = $VersionString.Trim()
    $match = [regex]::Match($normalized, '^(?<Core>\d+(?:\.\d+){1,3})$')
    if (-not $match.Success) { return $null }

    return [version]$match.Groups['Core'].Value
}

function Get-QemuGARemoteComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Metadata
    )

    if ($null -eq $Metadata) { return $null }

    # Parse Core string directly (e.g. "110.0.2") instead of rebuilding from SortCore fields.
    # Rebuilding always produces a 4-part version (e.g. "110.0.2.0"), but PowerShell's [version]
    # treats a missing 4th component as -1, so [version]"110.0.2" -ge [version]"110.0.2.0" = $false.
    # Parsing the original Core string preserves the correct component count for a fair comparison.
    try {
        return [version]$Metadata.Core
    } catch {
        return $null
    }
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
    }
    catch {
        Write-Log -Message "Failed to install $MsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    # --- Cleanup ---
    $doCleanup = $AutoCleanup
    if (-not $doCleanup) {
        $cleanupAnswer = Read-Host "Should the downloaded MSI file be deleted? (y/N)"
        $doCleanup = $cleanupAnswer -match "^[Yy]"
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

#EndRegion

#Region Script

Write-Log -Message "=== Update-VirtIO-QemuGA.ps1 v$ScriptVersion started ===" -Level "Info"

if (-not $Force) {
    $confirm = Read-Host "Should the VirtIO drivers and the QEMU Guest Agent be updated? (y/N)"
    if ($confirm -notmatch "^[Yy]") {
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

# --- Resolve latest VirtIO version from FPA ---
try {
    $FPAVirtIORootSite = Invoke-WebRequest -Uri $ArchiveVirtIOURL -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Log -Message "Failed to access Fedora People Archive at $ArchiveVirtIOURL. Error: $_" -Level "Error"
    exit 1
}

if ($FPAVirtIORootSite.StatusCode -ne 200) {
    Write-Log -Message "Failed to access Fedora People Archive at $ArchiveVirtIOURL. Status Code: $($FPAVirtIORootSite.StatusCode)" -Level "Error"
    exit 1
}
Write-Log -Message "Successfully accessed Fedora People Archive at $ArchiveVirtIOURL" -Level "Info"

$FPAVirtIODirectoryLinks = $FPAVirtIORootSite.Links |
    Where-Object { $_.href -match 'virtio-win-[\d\.]+-\d+/?$' } |
    ForEach-Object {
        $ver = [regex]::Match($_.href, 'virtio-win-([\d\.]+-\d+)').Groups[1].Value
        [PSCustomObject]@{ Href = $_.href; Version = $ver }
    }

$VirtIOLatest = $FPAVirtIODirectoryLinks |
    Sort-Object { [version]($_.Version -replace '-', '.') } -Descending |
    Select-Object -First 1

if ($null -eq $VirtIOLatest) {
    Write-Log -Message "No matching virtio-win version folders found in $ArchiveVirtIOURL" -Level "Error"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($VirtIOCurrentVersion)) {
    $VirtIOLocalComparableVersion  = Get-VirtIOComparableVersion -VersionString $VirtIOCurrentVersion
    $VirtIORemoteComparableVersion = Get-VirtIOComparableVersion -VersionString $VirtIOLatest.Version

    if ($null -eq $VirtIOLocalComparableVersion -or $null -eq $VirtIORemoteComparableVersion) {
        Write-Log -Message "VirtIO version format is incompatible for comparison (local='$VirtIOCurrentVersion', remote='$($VirtIOLatest.Version)'). VirtIO update will be skipped." -Level "Error"
        $SkipVirtIO = $true
    }
    elseif ($VirtIOLocalComparableVersion -ge $VirtIORemoteComparableVersion) {
        Write-Log -Message "VirtIO is already up to date or newer (local='$VirtIOCurrentVersion', remote='$($VirtIOLatest.Version)'). Skipping VirtIO installation." -Level "Info"
        $SkipVirtIO = $true
    }
    else {
        Write-Log -Message "VirtIO update required (local='$VirtIOCurrentVersion', remote='$($VirtIOLatest.Version)')." -Level "Info"
    }
}

if (-not $SkipVirtIO) {
    $FPAVirtIOLatestURL = ([Uri]::new([Uri]$ArchiveVirtIOURL, $VirtIOLatest.Href)).AbsoluteUri
    if (-not $FPAVirtIOLatestURL.EndsWith('/')) { $FPAVirtIOLatestURL += '/' }

    try {
        $FPAVirtIOLatestSite = Invoke-WebRequest -Uri $FPAVirtIOLatestURL -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to access latest virtio-win directory at $FPAVirtIOLatestURL. Error: $_" -Level "Error"
        exit 1
    }

    if ($FPAVirtIOLatestSite.StatusCode -ne 200) {
        Write-Log -Message "Failed to access latest virtio-win directory at $FPAVirtIOLatestURL. Status Code: $($FPAVirtIOLatestSite.StatusCode)" -Level "Error"
        exit 1
    }

    $VirtIOmsiLink = $FPAVirtIOLatestSite.Links | Where-Object { $_.href -eq $VirtIOmsiFileName } | Select-Object -First 1
    if ($null -eq $VirtIOmsiLink) {
        Write-Log -Message "Could not find $VirtIOmsiFileName in the latest directory." -Level "Error"
        exit 1
    }

    $VirtIOmsiDownloadURL = $FPAVirtIOLatestURL + $VirtIOmsiFileName

    Install-MsiPackage `
        -DisplayName "VirtIO" `
        -MsiFileName $VirtIOmsiFileName `
        -DownloadURL $VirtIOmsiDownloadURL
}

# --- Resolve latest QEMU GA version from FPA ---
try {
    $FPAQemuGARootSite = Invoke-WebRequest -Uri $ArchiveQemuGAURL -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Log -Message "Failed to access Fedora People Archive at $ArchiveQemuGAURL. Error: $_" -Level "Error"
    exit 1
}

if ($FPAQemuGARootSite.StatusCode -ne 200) {
    Write-Log -Message "Failed to access Fedora People Archive at $ArchiveQemuGAURL. Status Code: $($FPAQemuGARootSite.StatusCode)" -Level "Error"
    exit 1
}
Write-Log -Message "Successfully accessed Fedora People Archive at $ArchiveQemuGAURL" -Level "Info"

$FPAQemuGADirectoryLinks = $FPAQemuGARootSite.Links |
    ForEach-Object { Get-QemuGAFolderMetadata -Href $_.href } |
    Where-Object { $_ -ne $null }

$QemuGALatest = $FPAQemuGADirectoryLinks |
    Sort-Object -Property SortCore1, SortCore2, SortCore3, SortCore4, Release, DistMajor, DistMinor -Descending |
    Select-Object -First 1

if ($null -eq $QemuGALatest) {
    Write-Log -Message "No matching qemu-ga-win version folders found in $ArchiveQemuGAURL" -Level "Error"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
    $QemuGALocalComparableVersion  = Get-QemuGALocalComparableVersion -VersionString $QemuGACurrentVersion
    $QemuGARemoteComparableVersion = Get-QemuGARemoteComparableVersion -Metadata $QemuGALatest

    if ($null -eq $QemuGALocalComparableVersion -or $null -eq $QemuGARemoteComparableVersion) {
        Write-Log -Message "QEMU Guest Agent version format is incompatible for comparison (local='$QemuGACurrentVersion', remote='$($QemuGALatest.Core)-$($QemuGALatest.Release)'). QEMU Guest Agent update will be skipped." -Level "Error"
        $SkipQemuGA = $true
    }
    elseif ($QemuGALocalComparableVersion -ge $QemuGARemoteComparableVersion) {
        Write-Log -Message "QEMU Guest Agent is already up to date or newer (local='$QemuGACurrentVersion', remote='$($QemuGALatest.Core)'). Skipping QEMU Guest Agent installation." -Level "Info"
        $SkipQemuGA = $true
    }
    else {
        Write-Log -Message "QEMU Guest Agent update required (local='$QemuGACurrentVersion', remote='$($QemuGALatest.Core)')." -Level "Info"
    }
}

if (-not $SkipQemuGA) {
    $FPAQemuGALatestURL = ([Uri]::new([Uri]$ArchiveQemuGAURL, $QemuGALatest.Href)).AbsoluteUri
    if (-not $FPAQemuGALatestURL.EndsWith('/')) { $FPAQemuGALatestURL += '/' }

    Write-Log -Message "Selected latest QEMU GA folder: $($QemuGALatest.Href) (Core=$($QemuGALatest.Core), Release=$($QemuGALatest.Release), Dist=$($QemuGALatest.Dist))" -Level "Info"

    try {
        $FPAQemuGALatestSite = Invoke-WebRequest -Uri $FPAQemuGALatestURL -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to access latest qemu-ga directory at $FPAQemuGALatestURL. Error: $_" -Level "Error"
        exit 1
    }

    if ($FPAQemuGALatestSite.StatusCode -ne 200) {
        Write-Log -Message "Failed to access latest qemu-ga directory at $FPAQemuGALatestURL. Status Code: $($FPAQemuGALatestSite.StatusCode)" -Level "Error"
        exit 1
    }

    $QemuGAMsiLink     = $null
    $QemuGAmsiFileName = $null
    foreach ($msiCandidate in $QemuGAmsiCandidates) {
        $QemuGAMsiLink = $FPAQemuGALatestSite.Links | Where-Object { $_.href -eq $msiCandidate } | Select-Object -First 1
        if ($null -ne $QemuGAMsiLink) {
            $QemuGAmsiFileName = $msiCandidate
            break
        }
    }

    if ($null -eq $QemuGAMsiLink -or [string]::IsNullOrWhiteSpace($QemuGAmsiFileName)) {
        Write-Log -Message "Could not find a supported QEMU Guest Agent MSI file in the latest directory. Checked: $($QemuGAmsiCandidates -join ', ')" -Level "Error"
        exit 1
    }

    $QemuGAmsiDownloadURL = $FPAQemuGALatestURL + $QemuGAmsiFileName

    Install-MsiPackage `
        -DisplayName "QEMU Guest Agent" `
        -MsiFileName $QemuGAmsiFileName `
        -DownloadURL $QemuGAmsiDownloadURL
}

# --- Reboot handling ---
if ($script:RebootRequired) {
    Write-Log -Message "At least one installation requires a system reboot." -Level "Warning"

    $doReboot = $AutoReboot
    if (-not $doReboot) {
        $restartAnswer = Read-Host "A reboot is required to finalize installation. Restart now? (y/N)"
        $doReboot = $restartAnswer -match "^[Yy]"
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
        $confirmVioSCSI   = Read-Host "Do you want to install a dummy vioscsi device now? (y/N)"
        $doInstallVioSCSI = $confirmVioSCSI -match "^[Yy]"
    }

    if ($doInstallVioSCSI) {
        # Credit: vioscsi dummy device installer by croit
        # https://github.com/croit/load-virtio-scsi-on-boot
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
            & $dummyScriptPath
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