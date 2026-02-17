<#
.SYNOPSIS
    Updates VirtIO Windows drivers and prepares QEMU Guest Agent update workflow from Fedora People Archive.
.DESCRIPTION
    This script runs on Windows and automates the update process for VirtIO components sourced from the Fedora People Archive root URL.
    It performs environment validation (OS and administrator rights), checks currently installed versions, resolves the latest available
    archive version, downloads the MSI package to a temporary working directory, installs it silently, writes structured logs, and optionally
    cleans up downloaded installer files.

    The script is designed to be PowerShell 5.1 and PowerShell 7 compatible.

.EXAMPLE
    .\Update-VirtIO-QemuGA.ps1
    Runs the script interactively, downloads the latest VirtIO MSI, installs it, and prompts for cleanup.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Update-VirtIO-QemuGA.ps1
    Executes the script from Windows PowerShell 5.1 in a controlled invocation context.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    None. The script writes status information to console and log file.

.NOTES
    ScriptName        : Update-VirtIO-QemuGA.ps1
    Version           : 0.1.0
    Author            : Frederik S. (fs1n)
    License           : MIT License

.LINK
    TO_BE_REPLACED_DOCUMENTATION_URL
#>

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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

#Region Variables

# Define Variables
# FPA Is used as the alias for Fedora People Archive in the script
$FPARootURL = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads"
$ArchiveVirtIOURL = "$FPARootURL/archive-virtio/"
$ArchiveQemuGAURL = "$FPARootURL/archive-qemu-ga/"

$UninstallRegistryPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$VirtIODisplayNamePattern = "*virtio*installer*"
$VirtIOmsiFileName = "virtio-win-gt-x64.msi"
$QemuGAFolderPattern = '^qemu-ga-win-(?<Core>\d+(?:\.\d+){0,3})-(?<Release>\d+)(?:\.(?<Dist>[^/]+))?/?$'
$QemuGAmsiCandidates = @(
    "qemu-ga-x86_64.msi",
    "qemu-ga-x64.msi"
)
$QemuGAExecutablePaths = @(
    'C:\Program Files\Qemu-ga\qemu-ga.exe',
    'C:\Program Files (x86)\Qemu-ga\qemu-ga.exe'
)

$ScriptTempDirName = "Qemu-VirtIO-Update-Temp"
$ScriptTempPath = Join-Path -Path $env:TEMP -ChildPath $ScriptTempDirName
if (-not (Test-Path -Path $ScriptTempPath)) {
    New-Item -Path $ScriptTempPath -ItemType Directory | Out-Null
}
$script:LogFilePath = Join-Path -Path $ScriptTempPath -ChildPath "log_$(Get-Date -Format 'yyyy-MM-dd').log"
$script:RebootRequired = $false

#EndRegion

#Region Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes log messages to a file with timestamp and severity level. 
    
    .DESCRIPTION
        Logs script events with Info, Warning, or Error levels using European date/time format (dd. MM.yyyy HH:mm:ss).
    
    .PARAMETER Message
        The message to log. 
    
    .PARAMETER Level
        The severity level:  Info, Warning, or Error.  Default is Info.
    
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
    
    # European date/time format: dd.MM.yyyy HH:mm:ss
    $timestamp = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
    
    # Format the log entry
    $logEntry = "$timestamp [$Level] $Message"
    
    # Ensure log file exists
    if (-not (Test-Path -Path $script:LogFilePath)) {
        New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
        Add-Content -Path $script:LogFilePath -Value "=== Log initialized on $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') ==="
    }
    
    # Write to log file
    Add-Content -Path $script:LogFilePath -Value $logEntry
    
    # Also output to console with color coding
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
    if (-not $match.Success) {
        return $null
    }

    $coreRaw = $match.Groups['Core'].Value
    $coreParts = $coreRaw.Split('.')
    $core1 = 0
    $core2 = 0
    $core3 = 0
    $core4 = 0

    if ($coreParts.Count -ge 1) { $core1 = [int]$coreParts[0] }
    if ($coreParts.Count -ge 2) { $core2 = [int]$coreParts[1] }
    if ($coreParts.Count -ge 3) { $core3 = [int]$coreParts[2] }
    if ($coreParts.Count -ge 4) { $core4 = [int]$coreParts[3] }

    $release = [int]$match.Groups['Release'].Value
    $distRaw = $match.Groups['Dist'].Value
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

    if ([string]::IsNullOrWhiteSpace($VersionString)) {
        return $null
    }

    $normalized = $VersionString.Trim()
    $match = [regex]::Match($normalized, '^(?<Core>\d+(?:\.\d+){1,3})(?:-(?<Release>\d+))?$')
    if (-not $match.Success) {
        return $null
    }

    $core = $match.Groups['Core'].Value
    if ($match.Groups['Release'].Success) {
        return [version]("$core.$($match.Groups['Release'].Value)")
    }

    return [version]$core
}

function Get-QemuGALocalComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionString
    )

    if ([string]::IsNullOrWhiteSpace($VersionString)) {
        return $null
    }

    $normalized = $VersionString.Trim()
    $match = [regex]::Match($normalized, '^(?<Core>\d+(?:\.\d+){1,3})$')
    if (-not $match.Success) {
        return $null
    }

    return [version]$match.Groups['Core'].Value
}

function Get-QemuGARemoteComparableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Metadata
    )

    if ($null -eq $Metadata) {
        return $null
    }

    return [version]("$($Metadata.SortCore1).$($Metadata.SortCore2).$($Metadata.SortCore3).$($Metadata.SortCore4)")
}

#EndRegion

#Region Script

$confirm = Read-Host "Should the virtIO-Drivers and the QEMU Guest Agent be updated? (y/N)"
if ($confirm -notmatch "^[Yy]") {
    Write-Host "Script Canceled." -ForegroundColor Yellow
    exit 0
}

$SkipVirtIO = $false
$SkipQemuGA = $false

# Test if VirtIO Drivers are installed and get the current version
# Needed to then compare with latest version -> Override option to force reinstall will be added at some point. (ToDo)
try {
    $VirtIOCurrentVersion = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like $VirtIODisplayNamePattern } |
        Select-Object -ExpandProperty DisplayVersion -First 1

    if ([string]::IsNullOrWhiteSpace($VirtIOCurrentVersion)) {
        Write-Log -Message "VirtIO not installed (no matching registry entry found)." -Level "Warning"
    } else {
        Write-Log -Message "Detected VirtIO version: $VirtIOCurrentVersion" -Level "Info"
    }
}
catch {
    Write-Log -Message "Unable to retrieve VirtIO version: $_" -Level "Warning"
}

# Test if QEMU Guest Agent is installed and get current version
try {
    $QemuGACurrentVersion = $null

    foreach ($path in $QemuGAExecutablePaths) {
        if (Test-Path -Path $path) {
            $QemuGACurrentVersion = (Get-Item -Path $path -ErrorAction Stop).VersionInfo.FileVersion
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
        Write-Log -Message "QEMU Guest Agent not installed (qemu-ga.exe not found)." -Level "Warning"
    } else {
        Write-Log -Message "Detected QEMU Guest Agent version: $QemuGACurrentVersion" -Level "Info"
    }
}
catch {
    Write-Log -Message "Unable to retrieve QEMU Guest Agent version: $_" -Level "Warning"
}

# Access the Fedora People Archive to find the latest virtio-win version
try {
    $FPAVirtIORootSite = Invoke-WebRequest -Uri $ArchiveVirtIOURL -UseBasicParsing
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

$FPAVirtIOdirectoryLinks = $FPAVirtIORootSite.Links |
    Where-Object { $_.href -match 'virtio-win-[\d\.]+-\d+/?$' } |
    ForEach-Object {
        $ver = [regex]::Match($_.href, 'virtio-win-([\d\.]+-\d+)').Groups[1].Value
        [PSCustomObject]@{ Href = $_.href; Version = $ver }
    }

$latest = $FPAVirtIOdirectoryLinks |
    Sort-Object { [version]($_.Version -replace '-', '.') } -Descending |
    Select-Object -First 1

if ($null -eq $latest) {
    Write-Log -Message "No matching virtio-win version folders found in $ArchiveVirtIOURL" -Level "Error"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($VirtIOCurrentVersion)) {
    $VirtIOLocalComparableVersion = Get-VirtIOComparableVersion -VersionString $VirtIOCurrentVersion
    $VirtIORemoteComparableVersion = Get-VirtIOComparableVersion -VersionString $latest.Version

    if ($null -eq $VirtIOLocalComparableVersion -or $null -eq $VirtIORemoteComparableVersion) {
        Write-Log -Message "VirtIO version format is incompatible for comparison (local='$VirtIOCurrentVersion', remote='$($latest.Version)'). VirtIO update will be skipped." -Level "Error"
        $SkipVirtIO = $true
    }
    elseif ($VirtIOLocalComparableVersion -ge $VirtIORemoteComparableVersion) {
        Write-Log -Message "VirtIO is already up to date or newer (local='$VirtIOCurrentVersion', remote='$($latest.Version)'). Skipping VirtIO installation." -Level "Info"
        $SkipVirtIO = $true
    }
    else {
        Write-Log -Message "VirtIO update required (local='$VirtIOCurrentVersion', remote='$($latest.Version)')." -Level "Info"
    }
}

if (-not $SkipVirtIO) {
    $FPAVirtIOlatestURL = ([Uri]::new([Uri]$ArchiveVirtIOURL, $latest.Href)).AbsoluteUri
    if (-not $FPAVirtIOlatestURL.EndsWith('/')) {
        $FPAVirtIOlatestURL += '/'
    }

    try {
        $FPAVirtIOlatestSite = Invoke-WebRequest -Uri $FPAVirtIOlatestURL -UseBasicParsing
    }
    catch {
        Write-Log -Message "Failed to access latest virtio-win directory at $FPAVirtIOlatestURL. Error: $_" -Level "Error"
        exit 1
    }

    if ($FPAVirtIOlatestSite.StatusCode -ne 200) {
        Write-Log -Message "Failed to access latest virtio-win directory at $FPAVirtIOlatestURL. Status Code: $($FPAVirtIOlatestSite.StatusCode)" -Level "Error"
        exit 1
    }

    $VirtIOmsiLocalPath = Join-Path -Path $ScriptTempPath -ChildPath $VirtIOmsiFileName 

    $VirtIOmsiLink = $FPAVirtIOlatestSite.Links | Where-Object { $_.href -eq $VirtIOmsiFileName } | Select-Object -First 1

    if ($null -eq $VirtIOmsiLink) {
        Write-Log -Message "Could not find $VirtIOmsiFileName in the latest directory." -Level "Error"
        exit 1
    }

    # Construct the full download URL
    $VirtIOmsiDownloadURL = $FPAVirtIOlatestURL + $VirtIOmsiFileName
    Write-Log -Message "Download URL: $VirtIOmsiDownloadURL" -Level "Info"

    # Start download
    Write-Log -Message "Starting download to: $ScriptTempPath" -Level "Info"

    try {
        Invoke-WebRequest -Uri $VirtIOmsiDownloadURL -OutFile $VirtIOmsiLocalPath -UseBasicParsing
        Write-Log -Message "Successfully downloaded $VirtIOmsiFileName" -Level "Info"
    } catch {
        Write-Log -Message "Failed to download $VirtIOmsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    # Install the MSI
    Write-Log -Message "Starting installation of $VirtIOmsiFileName" -Level "Info"
    try {
        $installProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$VirtIOmsiLocalPath`" /qn /norestart" -Wait -PassThru
        if ($installProcess.ExitCode -in 0, 3010) {
            Write-Log -Message "Successfully installed $VirtIOmsiFileName" -Level "Info"
            if ($installProcess.ExitCode -eq 3010) {
                $script:RebootRequired = $true
                Write-Log -Message "VirtIO installation requires a reboot (ExitCode 3010)." -Level "Warning"
            }
        } else {
            Write-Log -Message "Installation of $VirtIOmsiFileName failed with exit code $($installProcess.ExitCode)" -Level "Error"
            exit 1
        }
    } catch {
        Write-Log -Message "Failed to install $VirtIOmsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    $CleanupConfirm = Read-Host "Should the downloaded MSI file be deleted? (y/N)"
    if ($CleanupConfirm -match "^[Yy]") {
        try {
            Remove-Item -Path $VirtIOmsiLocalPath -Force
            Write-Log -Message "Deleted downloaded MSI file: $VirtIOmsiLocalPath" -Level "Info"
        } catch {
            Write-Log -Message "Failed to delete downloaded MSI file: $VirtIOmsiLocalPath. Error: $_" -Level "Warning"
        }
    } else {
        Write-Log -Message "Downloaded MSI file retained at: $VirtIOmsiLocalPath" -Level "Info"
    }
}

# Access the Fedora People Archive to find the latest qemu-ga version
try {
    $FPAQemuGARootSite = Invoke-WebRequest -Uri $ArchiveQemuGAURL -UseBasicParsing
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
    ForEach-Object {
        Get-QemuGAFolderMetadata -Href $_.href
    } |
    Where-Object { $_ -ne $null }

$QemuGALatest = $FPAQemuGADirectoryLinks |
    Sort-Object -Property SortCore1, SortCore2, SortCore3, SortCore4, Release, DistMajor, DistMinor -Descending |
    Select-Object -First 1

if ($null -eq $QemuGALatest) {
    Write-Log -Message "No matching qemu-ga-win version folders found in $ArchiveQemuGAURL" -Level "Error"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($QemuGACurrentVersion)) {
    $QemuGALocalComparableVersion = Get-QemuGALocalComparableVersion -VersionString $QemuGACurrentVersion
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
    if (-not $FPAQemuGALatestURL.EndsWith('/')) {
        $FPAQemuGALatestURL += '/'
    }

    Write-Log -Message "Selected latest QEMU GA folder: $($QemuGALatest.Href) (Core=$($QemuGALatest.Core), Release=$($QemuGALatest.Release), Dist=$($QemuGALatest.Dist))" -Level "Info"

    try {
        $FPAQemuGALatestSite = Invoke-WebRequest -Uri $FPAQemuGALatestURL -UseBasicParsing
    }
    catch {
        Write-Log -Message "Failed to access latest qemu-ga directory at $FPAQemuGALatestURL. Error: $_" -Level "Error"
        exit 1
    }

    if ($FPAQemuGALatestSite.StatusCode -ne 200) {
        Write-Log -Message "Failed to access latest qemu-ga directory at $FPAQemuGALatestURL. Status Code: $($FPAQemuGALatestSite.StatusCode)" -Level "Error"
        exit 1
    }

    $QemuGAMsiLink = $null
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

    $QemuGAmsiLocalPath = Join-Path -Path $ScriptTempPath -ChildPath $QemuGAmsiFileName
    $QemuGAmsiDownloadURL = $FPAQemuGALatestURL + $QemuGAmsiFileName
    Write-Log -Message "QEMU Guest Agent download URL: $QemuGAmsiDownloadURL" -Level "Info"
    Write-Log -Message "Starting QEMU Guest Agent download to: $ScriptTempPath" -Level "Info"

    try {
        Invoke-WebRequest -Uri $QemuGAmsiDownloadURL -OutFile $QemuGAmsiLocalPath -UseBasicParsing
        Write-Log -Message "Successfully downloaded $QemuGAmsiFileName" -Level "Info"
    }
    catch {
        Write-Log -Message "Failed to download $QemuGAmsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    Write-Log -Message "Starting installation of $QemuGAmsiFileName" -Level "Info"
    try {
        $qemuInstallProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$QemuGAmsiLocalPath`" /qn /norestart" -Wait -PassThru
        if ($qemuInstallProcess.ExitCode -in 0, 3010) {
            Write-Log -Message "Successfully installed $QemuGAmsiFileName" -Level "Info"
            if ($qemuInstallProcess.ExitCode -eq 3010) {
                $script:RebootRequired = $true
                Write-Log -Message "QEMU Guest Agent installation requires a reboot (ExitCode 3010)." -Level "Warning"
            }
        }
        else {
            Write-Log -Message "Installation of $QemuGAmsiFileName failed with exit code $($qemuInstallProcess.ExitCode)" -Level "Error"
            exit 1
        }
    }
    catch {
        Write-Log -Message "Failed to install $QemuGAmsiFileName. Error: $_" -Level "Error"
        exit 1
    }

    $QemuCleanupConfirm = Read-Host "Should the downloaded QEMU Guest Agent MSI file be deleted? (y/N)"
    if ($QemuCleanupConfirm -match "^[Yy]") {
        try {
            Remove-Item -Path $QemuGAmsiLocalPath -Force
            Write-Log -Message "Deleted downloaded MSI file: $QemuGAmsiLocalPath" -Level "Info"
        }
        catch {
            Write-Log -Message "Failed to delete downloaded MSI file: $QemuGAmsiLocalPath. Error: $_" -Level "Warning"
        }
    } else {
        Write-Log -Message "Downloaded MSI file retained at: $QemuGAmsiLocalPath" -Level "Info"
    }
}

if ($script:RebootRequired) {
    Write-Log -Message "At least one installation requires a system reboot." -Level "Warning"
    $RestartConfirm = Read-Host "A reboot is required to finalize installation. Restart now? (y/N)"
    if ($RestartConfirm -match "^[Yy]") {
        Write-Log -Message "User confirmed immediate reboot." -Level "Warning"
        try {
            Restart-Computer -Force
        }
        catch {
            Write-Log -Message "Failed to trigger system reboot. Error: $_" -Level "Error"
            exit 1
        }
    }
    else {
        Write-Log -Message "Reboot postponed by user. Please reboot later to complete installation." -Level "Warning"
    }
}

#EndRegion