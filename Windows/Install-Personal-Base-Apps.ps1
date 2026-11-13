
#Requires -Version 5.1
# Run from an elevated PowerShell session.

$Packages = @(
    @{ Name = "7-Zip";                  Id = "7zip.7zip" }
    @{ Name = "Bitwarden";              Id = "Bitwarden.Bitwarden" }
    @{ Name = "Brave";                  Id = "Brave.Brave" }
    @{ Name = "Citrix Workspace";       Id = "Citrix.Workspace" }
    @{ Name = "Discord";                Id = "Discord.Discord" }
    @{ Name = "Google Chrome";          Id = "Google.Chrome" }
    @{ Name = "KeePassXC";              Id = "KeePassXCTeam.KeePassXC" }
    @{ Name = "Git";                    Id = "Git.Git" }
    @{ Name = "Mozilla Firefox";        Id = "Mozilla.Firefox" }
    @{ Name = "Node.js LTS";            Id = "OpenJS.NodeJS.LTS" }
    @{ Name = "OpenSSL Light Win64";    Id = "ShiningLight.OpenSSL.Light" }
    @{ Name = "Obsidian";               Id = "Obsidian.Obsidian" }
    @{ Name = "PowerShell 7";           Id = "Microsoft.PowerShell" }
    @{ Name = "PuTTY";                  Id = "PuTTY.PuTTY" }
    @{ Name = "Python 3";               Id = "Python.Python.3.13" }
    @{ Name = "Tailscale";              Id = "Tailscale.Tailscale" }
    @{ Name = "VLC Media Player";       Id = "VideoLAN.VLC" }
    @{ Name = "VMware Remote Console";  Id = "VMware.VMwareRemoteConsole" }
)

$LogPath = Join-Path $env:TEMP "WingetInstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$Results = @()

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install or update Microsoft App Installer."
}

foreach ($Package in $Packages) {
    $Name = $Package.Name
    $Id = $Package.Id

    Write-Host "`nProcessing $Name ($Id)" -ForegroundColor Cyan

    $Installed = winget list --id $Id --exact `
        --accept-source-agreements 2>&1

    if ($LASTEXITCODE -eq 0 -and
        ($Installed -join "`n") -match [regex]::Escape($Id)) {
        $Status = "Already installed"
        Write-Host $Status -ForegroundColor Yellow
    }
    else {
        winget install --id $Id --exact `
            --source winget `
            --silent `
            --disable-interactivity `
            --accept-package-agreements `
            --accept-source-agreements

        if ($LASTEXITCODE -eq 0) {
            $Status = "Installed"
            Write-Host $Status -ForegroundColor Green
        }
        else {
            $Status = "Failed (Exit code: $LASTEXITCODE)"
            Write-Warning "$Name : $Status"
        }
    }

    $Results += [PSCustomObject]@{
        Application = $Name
        PackageId   = $Id
        Status      = $Status
        Timestamp   = Get-Date
    }
}

# Packages requiring manual verification or installation
Write-Host "`nManual installation / verification:" -ForegroundColor Yellow
Write-Host " - Macrium Reflect Free Edition"
Write-Host " - Task Manager TMOG"

$Results | Export-Csv -Path $LogPath -NoTypeInformation
$Results | Format-Table -AutoSize

Write-Host "`nInstallation log: $LogPath" -ForegroundColor Cyan
