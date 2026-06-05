# Update-VirtIO-QemuGA

A PowerShell script to automatically update **VirtIO Windows drivers** and the **QEMU Guest Agent**.
Useful for keeping Windows VMs on QEMU/KVM or Proxmox VE up to date.

[![Mirror VirtIO & QEMU-GA from Fedora Archive](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml/badge.svg)](https://github.com/fs1n/Update-VirtIO-QemuGA/actions/workflows/mirror-virtio.yml)


## Features

- Detects currently installed versions and diff's with current latest version
- Resolves and downloads the latest MSI from a `manifest.json` committed in this repository
- Checks for a `vioscsi` device and offers to also run a script to install a dummy `vioscsi` device for seamless migration from e.g. VMware
- Compatible with **PowerShell 5.1** and **PowerShell 7**
- Non-interactive mode for use in scheduled tasks or RMM tools (`-Force` implies `-AutoCleanup` and `-AutoReboot`)
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
.\Update-VirtIO-QemuGA.ps1 -VirtIOVersion "0.1.285" -QemuGAVersion "110.0.2"
```

### Pin a version, fully automated
```powershell
.\Update-VirtIO-QemuGA.ps1 -VirtIOVersion "0.1.285" -QemuGAVersion "110.0.2" -Force -AutoCleanup -AutoReboot
```

If the pinned version is not present in `manifest.json` the script aborts with a non-zero exit code and lists the available versions - it will not silently install something you did not ask for!

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
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/fs1n/Update-VirtIO-QemuGA/refs/heads/main/Update-VirtIO-QemuGA.ps1" -UseBasicParsing))) -Force
```


### **To find all possibilities look at the script header!**


## Parameters

| Parameter | Description |
|---|---|
| `-Force` | Skips ALL interactive prompts and runs non-interactively. Implicitly enables `-AutoCleanup` and `-AutoReboot`. Use this for fully automated / RMM-driven runs. |
| `-AutoCleanup` | Deletes downloaded MSI files after installation without prompting. Implicitly enabled by `-Force`. |
| `-AutoReboot` | Reboots automatically after installation if required (exit code 3010) without prompting. Implicitly enabled by `-Force`. |
| `-InstallVioSCSI` | Automatically installs the vioscsi dummy device without prompting. Has no effect if a vioscsi device is already present. |
| `-VirtIOVersion` | Pin a specific VirtIO version (e.g. `0.1.285-1`). Default `latest`. Must match a version listed in `manifest.json` exactly — see the version-format note below. |
| `-QemuGAVersion` | Pin a specific QEMU Guest Agent version (e.g. `110.0.2-1`). Default `latest`. Must match a version listed in `manifest.json` exactly — see the version-format note below. |

### Version format note

The Windows installer reports the **core** version (e.g. `0.1.285`) while the manifest entries include the **package release suffix** as published upstream (e.g. `0.1.285-1`). Both are the same release; the `-N` suffix is just a build counter. When you pin, use the manifest form, which is what `manifest.json` actually contains. The up-to-date check ignores the suffix, so an installed `0.1.285` is correctly recognised as equal to a manifest `0.1.285-1` and the script will skip instead of asking to install it.


## How it works

This script does not scrape `fedorapeople.org` at runtime, like it originally once did. That site is now protected by **Anubis** (a bot challenge), and direct archive-index requests from Windows PowerShell get blocked. Instead, the update flow is split between CI and the script:

1. A scheduled **GitHub Action** (`.github/workflows/mirror-virtio.yml`, runs weekly on Sunday at 03:00 UTC) launches a headless **Playwright/Chromium** browser, navigates the Fedora People Archive index pages, and discovers the available VirtIO and QEMU Guest Agent MSI files and their direct-download URLs.
2. The Action merges the result into the **`manifest.json`**.
3. When `Update-VirtIO-QemuGA.ps1` runs, it fetches `manifest.json`, picks the latest entry (or the version pinned via `-VirtIOVersion` / `-QemuGAVersion`), and downloads the MSI from the URL stored in the manifest.
4. Because the URLs in the manifest point straight at the MSI file, the download works reliably from a plain PowerShell `Invoke-WebRequest`.

This means the script is only as fresh as the most recent manifest. If a new upstream release is out, wait for (or trigger) the weekly Action run, then re-run the script. If you pin a version that isn't in the manifest yet, the script aborts with a non-zero exit code and a list of available versions, so an automated runner doesn't accidentally install something else.


## Logs

Each run writes a log file to:
```
%TEMP%\Qemu-VirtIO-Update-Temp\log_yyyy-MM-dd_HH-mm-ss.log
```


## Contributing

If you would like to contribute, have spotted an error or have any other feedback, please open a PR or issue.

### Use of AI

I generally see no issue in using AI for building stuff. I vibed some stuff too. I see this as a "more mission critical" tool so if you use AI to generate, Follow this rules:
- Review, stuff you don't fully understand should be looked up and understood.
- Check for "efficiency", AI sometimes overdoes a bit.


## License

[MIT](LICENSE)


## Credits

The vioscsi dummy device installer invoked by this script is provided by **croit**:
[croit/load-virtio-scsi-on-boot](https://github.com/croit/load-virtio-scsi-on-boot) — all credit for that component goes to them.