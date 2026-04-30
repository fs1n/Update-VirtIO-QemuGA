# Update-VirtIO-QemuGA

A PowerShell script to automatically update **VirtIO Windows drivers** and the **QEMU Guest Agent** from the [Fedora People Archive](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads). Useful for keeping Windows VMs on QEMU/KVM or Proxmox VE up to date.


## Features

- Detects currently installed versions and skips updates when already up to date
- Resolves and downloads the latest MSI from the Fedora People Archive
- Checks for a `vioscsi` device and offers to also run a Script to install a dummy `vioscsi` device for seemless migration to e.g. Proxmox VE
- Compatible with **PowerShell 5.1** and **PowerShell 7**
- Non-interactive mode for use in scheduled tasks or RMM tools


## Requirements

- Some Windows OS
- **Administrator privileges**
- Internet access and connection to `fedorapeople.org` & **THE** GitHub Domains


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
