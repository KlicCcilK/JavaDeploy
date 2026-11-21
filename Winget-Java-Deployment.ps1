#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Oracle.JDK LTS deployment script for Desktop Centrail and other domain deployments.
    Install winget and Oracle.JDK while removing all over version of Oracle.JDK

    Run from an elevated Windows PowerShell 5.1 window (the built-in
    powershell.exe, not pwsh).


.DESCRIPTION
    Oracle.JDK LTS deployment script for Desktop Centrail and other domain deployments.
    
    Run from an elevated Windows PowerShell 5.1 window (the built-in powershell.exe, not pwsh).

    Detects current Oracle.JDK LTS version, uninstalls all other Oracle.JDK versions, and installs the current LTS version.
    Only works on Oracle.JDK versions installed via winget. If the current LTS version is already installed, it will be skipped.

.EXAMPLE
    .\Winget-Java-Deployment.ps1
    Default run: bootstrap winget, remove other Oracle.JDK versions, install current LTS.

.EXAMPLE
    .\Winget-Java-Deployment.ps1 -SkipUninstall
    Install/update the current LTS without uninstalling other Oracle.JDK versions.

.EXAMPLE
    .\Winget-Java-Deployment.ps1 -SU -Keep131
    Skip uninstall of other versions and also keep Java 1.3.1 (using aliases).

.EXAMPLE
    .\Winget-Java-Deployment.ps1 -ReinstallLTS -WaitSeconds 300
    Force reinstall of the current LTS and wait up to 300 seconds for winget.

.EXAMPLE
    .\Winget-Java-Deployment.ps1 -RLTS -K131 -PollSeconds 5
    Reinstall current LTS, keep 1.3.1, and poll every 5 seconds (using aliases).
#>

[CmdletBinding()]
param(
    [int]$WaitSeconds = 180,
    [int]$PollSeconds = 3,
    [alias('SU')]
    [switch]$SkipUninstall, # Skip uninstall of all other Oracle.JDK versions
    [alias('K131')]
    [switch]$Keep131,       # Keep java 1.3.1 
    [alias('RLTS')]
    [switch]$ReinstallLTS   # Reinstall the current LTS version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 is required for PSGallery / GitHub on many PS 5.1 hosts.
# Using TLS 1.2 over TLS 1.3 for enhanced compatabililty 
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not raise TLS protocol: $($_.Exception.Message)"
}

# Allows scripts to run for one script session
# May not be needed depending on how the service level account is permissioned
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Simple output format
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
}

# Verify current user/account/service has admin permissions
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


function Get-WinGetCommand {
    # App execution aliases and SYSTEM/Sandbox PATH are unreliable.
    # Prefer the real binary under WindowsApps, then PATH.
    $candidates = @()

    $winApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $winApps) { $candidates += $winApps }

    $pkgDirs = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') `
        -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe' } |
        Sort-Object Name

    foreach ($dir in $pkgDirs) {
        $exe = Join-Path $dir.FullName 'winget.exe'
        if (Test-Path -LiteralPath $exe) { $candidates += $exe }
    }

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Test-WinGetReady {
    $exe = Get-WinGetCommand
    if (-not $exe) { return $false }
    try {
        $out = & $exe --version 2>&1
        if ($LASTEXITCODE -ne 0 -and $null -eq $LASTEXITCODE) { return $false }
        $text = ($out | Out-String)
        return ($text -match '\d+\.\d+')
    } catch {
        return $false
    }
}


function Test-RealExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        # WindowsApps app-execution aliases are 0-byte stubs. Skip them.
        return ($item.Length -gt 0)
    } catch {
        return $false
    }
}

function Get-PwshCommand {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
    )
    $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-RealExecutable -Path $path) { return $path }
    }
    return $null
}

function Invoke-PwshCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$Command
    )
    # Call via an argument array so Windows PowerShell 5.1 does not
    # re-tokenize the command string and feed pwsh both -File and -Command.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PwshPath @('-NoLogo', '-NoProfile', '-Command', $Command) 2>&1
        return ($out | Out-String)
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

function Test-PwshReady {
    $exe = Get-PwshCommand
    if (-not $exe) { return $false }
    try {
        $text = Invoke-PwshCommand -PwshPath $exe -Command '$PSVersionTable.PSVersion.ToString()'
        return ($text -match '7\.\d+')
    } catch {
        return $false
    }
}

# simple wait until condition met function with inverval in seconds
function Wait-Until {
    param(
        [scriptblock]$Condition,
        [string]$Name,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            Write-Host ("{0} is ready." -f $Name) -ForegroundColor Green
            return $true
        }
        Write-Host ("Waiting for {0}... ({1}s remaining)" -f $Name, [int]($deadline - (Get-Date)).TotalSeconds)
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Update-ProcessPath {
    # MSI/winget update Machine PATH in the registry; this process still
    # has the old PATH. Rebuild it, then prepend known install dirs.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts   = @()
    foreach ($chunk in @($machine, $user, $env:PATH)) {
        if ($chunk) { $parts += $chunk }
    }
    $env:PATH = ($parts -join ';')

    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ((Test-Path -LiteralPath $windowsApps) -and ($env:PATH -notlike "*$windowsApps*")) {
            $env:PATH = "$windowsApps;$env:PATH"
    }
}

function Register-DesktopAppInstaller {
    Write-Step "Registering Microsoft.DesktopAppInstaller by family name"

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Write-Host "RegisterByFamilyName completed."
    } catch {
        Write-Warning "RegisterByFamilyName did not succeed (common in Sandbox if the package is not staged): $($_.Exception.Message)"
    }

    # Alternate: re-register from an already-installed package location.
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (Test-Path -LiteralPath $manifest) {
                Write-Host "Re-registering from $manifest"
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        Write-Warning "Manifest re-register skipped: $($_.Exception.Message)"
    }

    # Win11 reset path if the package exists but is broken.
    try {
        $reset = Get-Command Reset-AppxPackage -ErrorAction SilentlyContinue
        if ($reset) {
            $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
            if ($pkg) {
                $pkg | Reset-AppxPackage -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } catch {
        # Reset-AppxPackage is not available on all builds.
    }
}

function Install-WinGetViaRepairModule {
    Write-Step "Bootstrapping WinGet with Microsoft.WinGet.Client (Sandbox-supported)"

	$savedConfirm = $ConfirmPreference
    $ConfirmPreference = 'None'
    try {
        Write-Host "Installing NuGet package provider (non-interactive)..."
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Confirm:$false
    } catch {
        Write-Warning "Install-PackageProvider NuGet: $($_.Exception.Message)"
    } finally {
        $ConfirmPreference = $savedConfirm
    }   

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Write-Host "Installing Microsoft.WinGet.Client module (AllUsers)..."
    Install-Module -Name Microsoft.WinGet.Client -Force -Confirm:$false -Scope AllUsers -AllowClobber -Repository PSGallery | Out-Null
    Import-Module Microsoft.WinGet.Client -Force

    if (-not (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)) {
        throw "Repair-WinGetPackageManager is not available after module install."
    }

    Write-Host "Running Repair-WinGetPackageManager -AllUsers..."
    Repair-WinGetPackageManager -AllUsers | Out-Null
}

function Get-LatestWinGetReleaseAssets {
    $api = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    $headers = @{
        'User-Agent' = 'Install-WinGetAndPowerShell7'
        'Accept'     = 'application/vnd.github+json'
    }
    return Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
}

function Install-WinGetFromGitHub {
    Write-Step "Falling back to GitHub App Installer MSIX bundle"

    $work = Join-Path $env:TEMP ('winget-bootstrap-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $release = Get-LatestWinGetReleaseAssets
        $assets  = @($release.assets)

        $bundle = $assets | Where-Object { $_.name -like 'Microsoft.DesktopAppInstaller*.msixbundle' } | Select-Object -First 1
        $license = $assets | Where-Object { $_.name -like '*License1.xml' } | Select-Object -First 1
        $depsZip = $assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1

        if (-not $bundle) {
            throw "Could not find DesktopAppInstaller msixbundle on the latest winget-cli release."
        }

        $bundlePath  = Join-Path $work $bundle.name
        Write-Host "Downloading $($bundle.name)..."
        Invoke-WebRequest -Uri $bundle.browser_download_url -OutFile $bundlePath -UseBasicParsing

        $licensePath = $null
        if ($license) {
            $licensePath = Join-Path $work $license.name
            Invoke-WebRequest -Uri $license.browser_download_url -OutFile $licensePath -UseBasicParsing
        }

        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }

        if ($depsZip) {
            $zipPath = Join-Path $work $depsZip.name
            Write-Host "Downloading dependencies..."
            Invoke-WebRequest -Uri $depsZip.browser_download_url -OutFile $zipPath -UseBasicParsing
            $depsDir = Join-Path $work 'deps'
            Expand-Archive -Path $zipPath -DestinationPath $depsDir -Force

            $depFiles = Get-ChildItem -Path $depsDir -Recurse -Include '*.appx','*.msix' |
                Where-Object { $_.FullName -match [regex]::Escape($arch) -or $_.Name -match $arch }

            foreach ($dep in $depFiles) {
                Write-Host "Installing dependency $($dep.Name)..."
                try {
                    Add-AppxPackage -Path $dep.FullName -ErrorAction Stop | Out-Null
                } catch {
                    if ($_.Exception.Message -notmatch '0x80073D06|0x80073CF0|higher version|already installed') {
                        Write-Warning "Dependency $($dep.Name): $($_.Exception.Message)"
                    }
                }
            }
        }

        Write-Host "Installing App Installer package..."
        try {
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Add-AppxPackage failed: $($_.Exception.Message). Trying provisioned install."
            if (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
                if ($licensePath) {
                    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -LicensePath $licensePath -ErrorAction Stop | Out-Null
                } else {
                    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -SkipLicense -ErrorAction Stop | Out-Null
                }
            } else {
                throw
            }
        }

        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-Prerequisites {

    write-host "Starting Get-Prerequisites"

    try {

        # Update the core modules (this often fixes the load failure)
        write-host "Installing/Updating PackageManagement and PowerShellGet modules"
        Install-Module -Name PackageManagement -Force -AllowClobber -Scope CurrentUser -ErrorAction Continue
        write-host "Installing/Updating PowerShellGet module"
        Install-Module -Name PowerShellGet -Force -AllowClobber -Scope CurrentUser -ErrorAction Continue

        # Install module for easy winget list splicing
        try { 
            Write-Host "Installing Microsoft.WinGet.Client module for easy winget list splicing"
            Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -SkipPublisherCheck -AcceptLicense -ErrorAction Continue
        } catch { write-host "Microsoft.WinGet.Client module install failed" }

    } catch { Write-Host "Get-Prerequisites failed" }

    write-host "Completed Get-Prerequisites"

}

# Helper script
function Get-JavaLTSCurrent {
    # Script that fetches current LTS version of oracle.JKD
    # Used for winget updating of Java script for domain deployments

    write-host "Starting Get-JavaLTSCurrent"

    try {
        # Returns the latest LTS major
        $json = Invoke-RestMethod -Uri "https://api.adoptium.net/v3/info/available_releases"
        $latestLts = $json.most_recent_lts

        # Then use this for winget
        $packageId = "Oracle.JDK.$latestLts"
    } catch { Write-Host "Get-JavaLTSCurrent failed"}

    write-host "Completed Get-JavaLTSCurrent"

    return $packageID 
}

# Removes current Oracle.JDK versions from the system except for the current LTS version
function Remove-JavaCurrentVersions {
    
    param([string]$Java_LTS)

    write-host "Starting Remove-JavaCurrentVersions"

    try {
        # Moving to prelflight
        # Get-Prerequisites -ErrorAction Continue

        # need to skip current LTS from uninstall if already installed
        $versions = Get-WinGetPackage | Where-Object { $_.Id -like 'Oracle.JDK*' } 
        
        if(-not $versions) { Write-Host "No Oracle.JDK versions found to uninstall" ; return } 
        
        else {
            
            Write-host "`nFound the following Oracle.JDK versions installed:"
            $versions | Format-Table Id -AutoSize

            # Skip uninstalling all Oracle.JDK versions if -SkipUninstall switch is used
            if($SkipUninstall) { Write-Host "`nSkipping uninstall of all Oracle.JDK versions due to -SkipUninstall [-SU] switch" ; return }

            $versions | ForEach-Object {
                
                $id = $_.Id
                
                write-host "`nLooking at $($id)..."
                # Skip uninstalling java 1.3.1 if -Keep131 switch is used
                if($Keep131 -and $id -eq "Oracle.JDK.1") { Write-Host "`nSkipping uninstall of Oracle.JDK.1.3.1 due to -Keep131 [-K131] switch" ; continue }

                # Skip uninstalling the current LTS version if -ReinstallLTS [-RLTS] switch is not used
                if($id -eq "$($Java_LTS)" -and $ReinstallLTS -eq $false) { Write-Host "Skipping uninstall of current LTS version $($Java_LTS)" ; continue }
                elseif ($ReinstallLTS -eq $true) { Write-Host "Uninstalling $($Java_LTS) due to -ReinstallLTS [-RLTS] switch throw" } 
                else { Write-Host "Uninstalling $($id)..." }
                
                winget uninstall --id $id -e --source winget --accept-source-agreements

            }
        }
    } catch { Write-Host "`nRemove-JavaCurrentVersions failed:`n$($_.Exception.Message)`n"
                Write-Host "$($_.ScriptStackTrace)`n"
                exit 1 
            }
    
    write-host "Completed Remove-JavaCurrentVersions"

}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Step "Preflight"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Warning "This script is intended to run under Windows PowerShell 5.1. Continuing anyway."
}
if (-not (Test-IsAdmin)) {
    throw "This script must be run from an elevated (Run as administrator) PowerShell 5 window."
}
Write-Host ("Host: {0}  PS: {1}  User: {2}" -f $env:COMPUTERNAME, $PSVersionTable.PSVersion, $env:USERNAME)
Update-ProcessPath

if (-not (Test-WinGetReady)) {
    Register-DesktopAppInstaller
    Update-ProcessPath
}

if (-not (Test-WinGetReady)) {
    try {
        Install-WinGetViaRepairModule
    } catch {
        Write-Warning "Repair-WinGetPackageManager path failed: $($_.Exception.Message)"
    }
    Update-ProcessPath
}

if (-not (Test-WinGetReady)) {
    Install-WinGetFromGitHub
    Update-ProcessPath
}

Write-Step "Waiting until winget is installed and running"
if (-not (Wait-Until -Condition { Test-WinGetReady } -Name 'winget' -TimeoutSeconds $WaitSeconds -IntervalSeconds $PollSeconds)) {
    throw "Timed out waiting for winget after $WaitSeconds seconds."
}
$wingetExe = Get-WinGetCommand
Write-Host "winget path: $wingetExe"
& $wingetExe --version | Out-Host

# MSI installers write Machine PATH in the registry; refresh this process.
Update-ProcessPath

Write-Step "Checking prerequisites"
Get-Prerequisites -ErrorAction Continue

Write-Step "Preflight Complete"
Write-Host "WinGet available."
Write-Host "A brand-new window reads PATH from the registry; this window needed a refresh."

# Detect, update/install Java
Write-Step "Moving on to installing/updating current Java LTS"

try {
    $Java_packageLTS = Get-JavaLTSCurrent
    Write-Host "Current Java LTS version is $($Java_packageLTS)"

    Write-Step "Removing current versions..."
    Remove-JavaCurrentVersions -Java_LTS $Java_packageLTS

    Write-Step "Installing current Java LTS..."
    $target = "$($Java_packageLTS)"
    write-host "Targeting $($target)"
    winget install --source winget --id $target -e --accept-source-agreements --accept-package-agreements --silent

    Write-Step "Updating current Java LTS..."
    winget update --source winget --id $target -e --accept-source-agreements --accept-package-agreements --silent


} catch { Write-Host "Failed installing/updating curren Java LTS"}

Write-Host "`Winget-Java-Deployment.ps1 complete." -ForegroundColor Green

exit 0