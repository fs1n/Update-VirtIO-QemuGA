# Update-VirtIO-QemuGA

A PowerShell script to automatically update **VirtIO Windows drivers** and the **QEMU Guest Agent** from the [Fedora People Archive](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads). Useful for keeping Windows VMs on QEMU/KVM or Proxmox VE up to date.

---

## Features

- Detects currently installed versions and skips updates when already up to date
- Resolves and downloads the latest MSI from the Fedora People Archive
- Silent MSI installation with prompt for reboot
- Checks for a `vioscsi` device and offers to install a dummy device for seamless Proxmox VE migration
- Compatible with **PowerShell 5.1** and **PowerShell 7**
- Non-interactive mode for use in scheduled tasks or RMM tools

---

## Requirements

- Windows - Tested on Server 22 others will follow
- **Administrator privileges**
- Internet access to `fedorapeople.org`

---

## Usage

### Interactive
```powershell
.\Update-VirtIO-QemuGA.ps1
```

### Fully automated (no prompts)
```powershell
.\Update-VirtIO-QemuGA.ps1 -Force -AutoCleanup -AutoReboot
```

### Via Windows PowerShell 5.1
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Update-VirtIO-QemuGA.ps1
```

---

## Parameters

| Parameter | Description |
|---|---|
| `-Force` | Skips the initial confirmation prompt |
| `-AutoCleanup` | Deletes downloaded MSI files after installation without prompting |
| `-AutoReboot` | Reboots automatically if required (exit code 3010), without prompting |

---

## Logs

Each run writes a log file to:
```
%TEMP%\Qemu-VirtIO-Update-Temp\log_yyyy-MM-dd_HH-mm-ss.log
```

---

## License

[MIT](LICENSE)

---

## Credits

The vioscsi dummy device installer invoked by this script is provided by **croit**:
[croit/load-virtio-scsi-on-boot](https://github.com/croit/load-virtio-scsi-on-boot) — all credit for that component goes to them.