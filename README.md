# Update-VirtIO-QemuGA

A PowerShell script to automatically update **VirtIO Windows drivers** and the **QEMU Guest Agent**.
Useful for keeping Windows VMs on QEMU/KVM or Proxmox VE up to date.

[![Mirror VirtIO & QEMU-GA from Fedora Archive](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml/badge.svg)](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml)

## Features

- Detects currently installed versions and skips updates when already up to date
- Resolves and downloads the latest MSI from a `manifest.json` committed in this repository, which tracks the Fedora People Archive (overcomes the Anubis bot protection that blocks direct scraping)
- Checks for a `vioscsi` device and offers to also run a Script to install a dummy `vioscsi` device for seemless migration to e.g. Proxmox VE
- Compatible with **PowerShell 5.1** and **PowerShell 7**
- Non-interactive mode for use in scheduled tasks or RMM tools
- Supports version pinning via `-VirtIOVersion` and `-QemuGAVersion`


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

### Pin a specific VirtIO and QEMU Guest Agent version
```powershell
.\Update-VirtIO-QemuGA.ps1 -VirtIOVersion "0.1.285-1" -QemuGAVersion "110.0.2-1"
```

### Pin a version, fully automated
```powershell
.\Update-VirtIO-QemuGA.ps1 -VirtIOVersion "0.1.285-1" -QemuGAVersion "110.0.2-1" -Force -AutoCleanup -AutoReboot
```

If the pinned version is not present in `manifest.json` the script aborts with a non-zero exit code and lists the available versions — it will not silently install something you did not ask for.

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
| `-VirtIOVersion` | Specify a VirtIO version to install (e.g. `0.1.285-1`). Default `latest`. Must match a version listed in `manifest.json`. |
| `-QemuGAVersion` | Specify a QEMU Guest Agent version to install (e.g. `110.0.2-1`). Default `latest`. Must match a version listed in `manifest.json`. |

## How it works

This script does not scrape `fedorapeople.org` at runtime — that site is now protected by **Anubis** (a bot challenge), and direct archive-index requests from Windows PowerShell get blocked. Instead, the update flow is split between CI and the script:

1. A scheduled **GitHub Action** (`.github/workflows/mirror-virtio.yml`, runs weekly on Sunday at 03:00 UTC) launches a headless **Playwright/Chromium** browser, navigates the Fedora People Archive index pages, and discovers the available VirtIO and QEMU Guest Agent MSI files and their direct-download URLs.
2. The Action writes the result to **`manifest.json`** at the repository root and commits it to `main`. The manifest is a small JSON document listing each known version, its filename, and the **direct** MSI URL.
3. When `Update-VirtIO-QemuGA.ps1` runs, it fetches `manifest.json` over HTTPS from `raw.githubusercontent.com`, picks the latest entry (or the version pinned via `-VirtIOVersion` / `-QemuGAVersion`), and downloads the MSI from the URL stored in the manifest.
4. Because the URLs in the manifest point straight at the MSI file (not the archive index page), the download is not challenged by Anubis and works reliably from a plain PowerShell `Invoke-WebRequest`.

This means the script is only as fresh as the most recent manifest. If a new upstream release is out, wait for (or trigger) the weekly Action run, then re-run the script. If you pin a version that isn't in the manifest yet, the script aborts with a non-zero exit code and a list of available versions, so an automated runner doesn't accidentally install something else.

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
