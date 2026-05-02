> [!CAUTION]
> **Script currently not working**
>
> `fedorapeople.org` changed their site protection - archive requests are being blocked by the new bot protection.
>
> **Fix is in progress.**

# Update-VirtIO-QemuGA

A PowerShell script to automatically update **VirtIO Windows drivers** and the **QEMU Guest Agent**.
Useful for keeping Windows VMs on QEMU/KVM or Proxmox VE up to date.

[![Mirror VirtIO & QEMU-GA from Fedora Archive](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml/badge.svg)](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml)

## Features

- Detects currently installed versions and skips updates when already up to date
- Checks for a `vioscsi` device and offers to also run a Script to install a dummy `vioscsi` device for seemless migration to e.g. Proxmox VE
- Compatible with **PowerShell 5.1** and **PowerShell 7**
- Non-interactive mode for use in scheduled tasks or RMM tools


## Requirements

- Some Windows OS (Tested on Windows 11, Server 22 and Server 25)
- **Administrator privileges**
- Internet access


## Usage

### Interactive
```powershell
.\Update-VirtIO-QemuGA.ps1
```

### Fully automated (no prompts)
```powershell
.\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot
```

### Interactive loaded directly from GitHub
```powershell
irm https://raw.githubusercontent.com/fs1n/Update-VirtIO-QemuGA/refs/heads/main/Update-VirtIO-QemuGA.ps1 | iex
```

### Interactive loaded from GitHub with Parameters
```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/fs1n/Update-VirtIO-QemuGA/refs/heads/main/Update-VirtIO-QemuGA.ps1" -UseBasicParsing))) <Parameter of your choice>
```

e.g. :

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/fs1n/Update-VirtIO-QemuGA/refs/heads/main/Update-VirtIO-QemuGA.ps1" -UseBasicParsing))) -Force -AutoCleanup
```


### **To find all possibilites look at the script header!**


## Parameters

| Parameter | Description |
|---|---|
| `-Force` | Skips the initial confirmation prompt |
| `-AutoCleanup` | Deletes downloaded MSI files after installation without prompting |
| `-AutoReboot` | Reboots automatically if required (exit code 3010), without prompting |
| `-InstallVioSCSI` | Automatically installs the vioscsi dummy device without prompting |
| `-VirtIOVersion` | Pin one of 3 available VirtIO versions to install |
| `-QemuGAVersion` | Pin one of 3 available Qemu GA versions to install |

## Logs

Each run writes a log file to:
```
%TEMP%\Qemu-VirtIO-Update-Temp\log_yyyy-MM-dd_HH-mm-ss.log
```


## Contributing

If you would like to contribute, have spotted an error or have any other feedback, please open a PR or issue.


## License

[MIT](LICENSE)


## Credits

The vioscsi dummy device installer invoked by this script is provided by **croit**:
[croit/load-virtio-scsi-on-boot](https://github.com/croit/load-virtio-scsi-on-boot) — all credit for that component goes to them.
