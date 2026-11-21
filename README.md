# Winget-Java-Deployment

PowerShell script for domain and endpoint management deployments (Desktop Central / Endpoint Central, SCCM, Intune, etc.) that bootstraps **winget** if needed, detects the current Oracle JDK LTS, removes older winget-installed Oracle.JDK versions, and installs/updates the current LTS.

## Requirements

- Windows 10 / 11 or Windows Server (with App Installer / winget support)
- **Elevated Windows PowerShell 5.1** (`powershell.exe`, not `pwsh`)
- Administrator / system privileges (`#Requires -RunAsAdministrator`)
- Internet access (PSGallery, GitHub, Adoptium API, winget sources)

## What it does

1. Ensures the process is elevated and running under Windows PowerShell 5.1.
2. Refreshes the process `PATH` so newly installed tools are visible in the same session.
3. Bootstraps **winget** if it is not already ready, using this order:
   - Re-register `Microsoft.DesktopAppInstaller`
   - Install the `Microsoft.WinGet.Client` module and run `Repair-WinGetPackageManager`
   - Fall back to downloading the latest App Installer MSIX bundle from the official winget-cli GitHub releases
4. Installs/updates the NuGet package provider and the `Microsoft.WinGet.Client` module (for reliable package querying).
5. Queries the Adoptium API for the current Java LTS major version.
6. Uninstalls any existing **Oracle.JDK.\*** packages installed via winget, except the current LTS.
7. Installs (and updates) the current LTS package (`Oracle.JDK.<major>`) via winget, silently.

> **Note:** Uninstall only affects Oracle.JDK packages that were installed with winget. Manual or MSI-based Java installs are not removed.

## Usage

```powershell
# From an elevated Windows PowerShell 5.1 window
powershell.exe -ExecutionPolicy Bypass -File .\Winget-Java-Deployment.ps1
```

### Parameters

| Parameter          | Alias   | Default | Description                                              |
|--------------------|---------|---------|----------------------------------------------------------|
| `-WaitSeconds`     |         | `180`   | Maximum time to wait for winget to become ready         |
| `-PollSeconds`     |         | `3`     | Interval between winget readiness checks                |
| `-SkipUninstall`   | `-SU`   |         | Skip uninstall of all other Oracle.JDK versions         |
| `-Keep131`         | `-K131` |         | Keep Java 1.3.1                                          |
| `-ReinstallLTS`    | `-RLTS` |         | Reinstall the current LTS version                       |

Example:

```powershell
.\Winget-Java-Deployment.ps1 -WaitSeconds 300 -PollSeconds 5
.\Winget-Java-Deployment.ps1 -SU -Keep131
.\Winget-Java-Deployment.ps1 -RLTS -w 300
```

## Exit codes

- `0` — Completed successfully
- `1` — Failure inside `Remove-JavaCurrentVersions` (or other unhandled terminating error)

## Desktop Central / Endpoint Central notes

- Deploy as a **Computer Configuration** custom script (or software package) so it runs elevated.
- Recommended command line:

  ```text
  powershell.exe -ExecutionPolicy Bypass -File Winget-Java-Deployment.ps1
  ```

- Enable **Enable logging for troubleshooting** (frequency = Once) to capture `Write-Host` output in the configuration’s Remarks / View Logs.
- The script is designed to be non-interactive (`-Force`, `-Confirm:$false`, silent winget flags).

## Behavior details

- Current LTS is detected at runtime from  
  `https://api.adoptium.net/v3/info/available_releases` (`most_recent_lts`).
- Package ID format used: `Oracle.JDK.<major>` (example: `Oracle.JDK.25`).
- Winget commands use `--accept-source-agreements`, `--accept-package-agreements`, and `--silent` where appropriate.
- Process PATH is refreshed after each winget bootstrap step so `winget.exe` is immediately usable.

## Limitations

- Only removes Oracle.JDK versions that appear in winget’s package list.
- Requires outbound HTTPS to PSGallery, GitHub, Adoptium, and the winget source.
- Intended for Windows PowerShell 5.1; behavior under PowerShell 7 is not the primary target.
- First-run winget bootstrap can take 1–3 minutes depending on network and machine state.

## License

MIT Licensed
