<#
.SYNOPSIS
    One-click solution to mirror iPhone screen to Windows PC using native AirPlay

.DESCRIPTION
    This script provides a simplified, professional experience for iPhone screen mirroring:
    - Automatically checks and installs requirements (UxPlay, Apple Bonjour)
    - Resolves common firewall conflicts automatically
    - Launches the AirPlay receiver with optimal settings
    - Provides clear instructions for iPhone mirroring
    - Includes built-in diagnostics and troubleshooting

    Features:
    ✅ One-click setup and launch
    ✅ Automatic firewall conflict resolution
    ✅ Professional logging and error handling
    ✅ Optimized for demos, presentations, and app sharing
    ✅ No iPhone app required - uses native Screen Mirroring

.PARAMETER SkipSetup
    Skips the initial setup process (useful if already configured)

.PARAMETER Name
    Custom name for your PC as it appears on iPhone (default: "My PC")

.PARAMETER Fullscreen
    Start mirroring in fullscreen mode

.PARAMETER PIN
    Require a 4-digit PIN for secure mirroring

.PARAMETER Sync
    Prefer A/V synchronization over the lowest latency

.PARAMETER Fps
    Cap the mirror stream at the selected frames per second

.PARAMETER NoAudio
    Disable audio output on the PC

.PARAMETER ShareSafe
    Use a capture-friendly video sink for Teams, Zoom, and recording tools

.PARAMETER SoftwareDecode
    Use software video decoding instead of the hardware decoder

.PARAMETER EngineDebug
    Enable verbose UxPlay logging

.EXAMPLE
    .\Mirror-iPhone.ps1
    # One-click setup and launch with default settings

.EXAMPLE
    .\Mirror-iPhone.ps1 -Name "Work Laptop" -PIN -Fullscreen
    # Custom name, PIN protection, and fullscreen mode

.NOTES
    Requires PowerShell 5.1 and Administrator privileges for initial setup.
    Once configured, can be run without admin for subsequent uses.
    Tested on Windows 10/11.
    iPhone must be on same Wi-Fi network as PC.
#>

[CmdletBinding()]
param(
    [switch]$SkipSetup,
    [string]$Name = "My PC",
    [switch]$Fullscreen,
    [switch]$PIN,
    [switch]$Sync,
    [ValidateRange(1, 60)]
    [int]$Fps = 60,
    [switch]$NoAudio,
    [switch]$ShareSafe,
    [switch]$SoftwareDecode,
    [switch]$EngineDebug
)

# Set up error handling and logging
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$logDir = Join-Path $env:LOCALAPPDATA 'ScreenMirroringiPhone'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logDir "mirror-$timestamp.log"

function Log($message, $level = "INFO") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $entry = "[$timestamp] [$level] $message"
    Write-Host $entry
    $entry | Out-File -FilePath $logFile -Append -Encoding utf8
}

function Show-Banner {
    Write-Host ""
    Write-Host "📱 Screen Mirroring for iPhone in Windows" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Help {
    Write-Host ""
    Write-Host "📱 Screen Mirroring for iPhone in Windows" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "One-click solution to mirror iPhone screen to Windows PC"
    Write-Host "using native AirPlay (no iPhone app required)."
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  .\Mirror-iPhone.ps1                 # Standard setup and launch"
    Write-Host "  .\Mirror-iPhone.ps1 -Name 'Work'    # Custom PC name"
    Write-Host "  .\Mirror-iPhone.ps1 -PIN            # Require PIN for security"
    Write-Host "  .\Mirror-iPhone.ps1 -Fullscreen     # Start in fullscreen"
    Write-Host ""
    Write-Host "AFTER LAUNCHING:"
    Write-Host "  1. On iPhone: Swipe down → Control Center → Screen Mirroring"
    Write-Host "  2. Select your PC name from the list"
    Write-Host "  3. Wait 5-10 seconds for mirroring to start"
    Write-Host ""
    Write-Host "To stop mirroring: Close this window or press Ctrl+C"
    Write-Host ""
}

# Handle help parameter
if ($args -contains '-?' -or $args -contains '-help' -or $args -contains '--help') {
    Show-Help
    exit 0
}

Show-Banner

# Step 1: Check if running as administrator (needed for setup/firewall changes)
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin
Log("Administrator privileges: $isAdmin")

# Step 2: Source required shared functions
Log("Loading shared functions...")
try {
    . (Join-Path $scriptDir '../uxplay-common.ps1')
    Log("Shared functions loaded successfully")
} catch {
    Log("ERROR: Failed to load shared functions from uxplay-common.ps1", "ERROR")
    Write-Host "`n❌ ERROR: Could not find required support files." -ForegroundColor Red
    Write-Host "   Please ensure this script is in the Screen Mirroring for iPhone in Windows folder" -ForegroundColor Yellow
    Write-Host "   alongside the original pcairplay repository files." -ForegroundColor Yellow
    exit 1
}

# Step 3: Main execution logic
try {
    if (-not $SkipSetup) {
        Log("Starting setup process...")

        # Check and install UxPlay if needed
        Log("Checking UxPlay installation...")
        $ux = Find-UxPlay
        if (-not $ux -or $ux.Kind -ne 'Cli') {
            Log("UxPlay not found or wrong version - installing...")

            # Try to run setup.ps1 from parent directory
            $setupScript = Join-Path $scriptDir '..\setup.ps1'
            if (Test-Path $setupScript) {
                Log("Running UxPlay installer...")
                & powershell -NoProfile -ExecutionPolicy Bypass -File $setupScript
                if ($LASTEXITCODE -ne 0) {
                    throw "UxPlay installation failed with exit code $LASTEXITCODE"
                }
                Log("UxPlay installation completed")
            } else {
                throw "Could not find setup.ps1 in parent directory"
            }
        } else {
            Log("UxPlay already installed: $($ux.Exe) (v$($ux.Version))")
        }

        # Check and ensure Apple Bonjour is running
        Log("Checking Apple Bonjour...")
        $bonjour = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
        if (-not $bonjour) {
            Log("Apple Bonjour service not found", "WARN")
            Write-Host "`n⚠️  WARNING: Apple Bonjour not found." -ForegroundColor Yellow
            Write-Host "   This is REQUIRED for iPhone to discover your PC." -ForegroundColor Yellow
            Write-Host "   Please install 'Bonjour Print Services for Windows':" -ForegroundColor Yellow
            Write-Host "   https://support.apple.com/kb/DL999" -ForegroundColor Yellow
            Write-Host ""
            $response = Read-Host "   Have you installed Bonjour? (y/n)"
            if ($response -notmatch '^[yY]') {
                throw "Apple Bonjour is required to continue"
            }
        }

        if ($bonjour.Status -ne 'Running') {
            Log("Starting Apple Bonjour service...")
            Set-Service -Name 'Bonjour Service' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'Bonjour Service' -ErrorAction Stop
            Log("Apple Bonjour service started")
        } else {
            Log("Apple Bonjour service is already running")
        }

        # Validate Bonjour is working
        $dnssd = "$env:SystemRoot\System32\dnssd.dll"
        if (-not (Test-Path $dnssd)) {
            throw "Bonjour runtime (dnssd.dll) not found at $dnssd"
        }
        Log("Bonjour runtime verified")

        # Handle firewall configuration
        Log("Configuring firewall rules...")
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir '..\setup.ps1') -WhatIf:$false
            Log("Firewall configuration completed")
        } catch {
            Log("Warning: Firewall configuration had issues: $($_.Exception.Message)", "WARN")
        }

        # Resolve common firewall conflicts automatically
        Log("Checking for conflicting firewall rules...")
        $conflictNames = @(
            'The Complete Business Accounting Software'
            # Add other known conflicts here if discovered
        )

        foreach ($conflictName in $conflictNames) {
            $existingRule = Get-NetFirewallRule -DisplayName $conflictName -ErrorAction SilentlyContinue
            if ($existingRule) {
                if ($existingRule.Enabled -eq 'True') {
                    Log("Found conflicting BLOCK rule: '$conflictName' - disabling automatically", "WARN")
                    try {
                        Set-NetFirewallRule -DisplayName $conflictName -Enabled False -ErrorAction Stop
                        Log("Disabled conflicting rule: '$conflictName'", "WARN")
                    } catch {
                        Log("Could not disable conflicting rule '$conflictName' - you may need to do this manually", "WARN")
                    }
                }
            }
        }

        Log("Setup process completed successfully")
    } else {
        Log("Skipping setup process (as requested)")
    }

    # Step 4: Validate current state before launching
    Log("Validating system state before launch...")
    $ux = Find-UxPlay
    if (-not $ux) {
        throw "UxPlay not found. Please run without -SkipSetup first."
    }

    if ($ux.Kind -ne 'Cli') {
        throw "UxPlay GUI-only version found. This script requires the command-line version."
    }

    Log("UxPlay validated: $($ux.Exe) v$($ux.Version)")

    # Check Bonjour one more time
    $bonjourSock = Get-BonjourSocketState
    if ($bonjourSock.State -ne 'Listening') {
        Log("WARNING: Bonjour is not properly listening on network interface", "WARN")
        $why = switch ($bonjourSock.State) {
            'Deaf' { 'running but has NO network mDNS socket' }
            'Stopped' { 'installed but not running' }
            'NoService' { 'not installed' }
            default { $bonjourSock.State }
        }
        Write-Host "`n⚠️  WARNING: Bonjour is $why" -ForegroundColor Yellow
        Write-Host "   iPhones may not be able to discover your PC." -ForegroundColor Yellow
        if ($bonjourSock.State -eq 'Deaf' -and $bonjourSock.Holders.Count -gt 0) {
            Write-Host "   UDP 5353 is held by: $($bonjourSock.Holders -join ', ')" -ForegroundColor Yellow
        }
        # Don't fail here - warn but continue, as sometimes it works anyway
    } else {
        Log("Bonjour network listener verified: $($bonjourSock.Address):5353")
    }

    # Step 5: Build and launch AirPlay receiver with user preferences
    Log("Building AirPlay launch parameters...")

    # Resolve device name
    $resolvedName = Resolve-UxPlayDeviceName -Name $Name
    if ($resolvedName.Error) {
        throw $resolvedName.Error
    }
    $finalName = $resolvedName.Name
    if ($resolvedName.Changed) {
        Log("Device name adjusted from '$Name' to '$finalName' (removed invalid characters)")
    }

    # Get UxPlay details for launch
    $ux = Find-UxPlay
    $pluginDir = $ux.PluginDir

    # Initialize UxPlay environment
    Initialize-UxPlayEnvironment -UxPlay $ux

    # Build argument list with user preferences
    $built = Build-UxPlayArgs `
        -Name $finalName `
        -Resolution '1920x1080' `
        -RefreshRate 60 `
        -Fps $Fps `
        -PluginDir $pluginDir `
        -Sync:$Sync `
        -Fullscreen:$Fullscreen `
        -Pin:$PIN `
        -SoftwareDecode:$SoftwareDecode `
        -ShareSafe:$ShareSafe `
        -NoAudio:$NoAudio `
        -EngineDebug:$EngineDebug

    $argList = $built.Args
    $notes = $built.Notes

    # Show launch information
    Log("Launch configuration:")
    Log("  Device name: $finalName")
    Log("  Video: 1920x1080 @ 60Hz (capped at 60fps)")
    $mode = if ($Sync) { 'A/V sync' } else { 'low latency' }
    Log("  Mode: $mode")
    Log("  FPS cap: $Fps")
    Log("  Fullscreen: $Fullscreen")
    Log("  PIN required: $PIN")
    foreach ($note in $notes) {
        Log("  Note: $note")
    }

    Log("Launching AirPlay receiver...")
    Log("Receiver address: $(Get-LanIPAddress)")
    Log("Logs will be saved to: $logDir")
    Log("")

    # Show user instructions
    Write-Host ""
    Write-Host "🚀 AirPlay receiver starting..." -ForegroundColor Green
    Write-Host "   Device name on iPhone: $finalName" -ForegroundColor Green
    Write-Host "   Your PC IP: $(Get-LanIPAddress)" -ForegroundColor Green
    Write-Host ""
    Write-Host "📱 To mirror your iPhone:"
    Write-Host "   1. Swipe down from top-right → Control Center"
    Write-Host "   2. Tap 'Screen Mirroring'"
    Write-Host "   3. Select '$finalName' from the list"
    Write-Host "   4. Wait 5-10 seconds for mirroring to start"
    Write-Host ""
    Write-Host "⌨️  Controls:"
    Write-Host "   Alt+Enter: Toggle fullscreen"
    Write-Host "   Ctrl+C: Stop mirroring and close this window"
    Write-Host ""
    Write-Host "💡 Tips:"
    Write-Host "   • For video playback: Re-run with -Sync flag"
    Write-Host "   • For added security: Re-run with -PIN flag"
    Write-Host "   • To change device name: Re-run with -Name 'Your Name'"
    Write-Host ""

    # Launch the receiver
    $logPath = New-PCAirPlayLogPath -Prefix 'mirror-iPhone'
    $startedAt = Get-Date

    try {
        if ($logPath) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & $ux.Exe @argList 2>&1 | Tee-Object -FilePath $logPath -Append }
            finally { $ErrorActionPreference = $prev }
        } else {
            & $ux.Exe @argList
        }
        $exitCode = $LASTEXITCODE
    } finally {
        if ($logPath) { Log("Receiver log saved to: $logPath") }

        # Cleanup any lingering uxplay processes from this session
        try {
            Get-CimInstance Win32_Process -Filter "Name = 'uxplay.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ParentProcessId -eq $PID } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }

    # Handle exit
    if (((Get-Date) - $startedAt).TotalSeconds -lt 3) {
        Log("Receiver exited immediately (code $exitCode) - it may not have started properly", "ERROR")
        Write-Host "`n❌ The receiver exited immediately. Check the log for details:" -ForegroundColor Red
        Write-Host "   $logPath" -ForegroundColor Yellow
        Write-Host "`n💡 Run .\doctor.ps1 to diagnose common issues" -ForegroundColor Yellow
    } else {
        Log("Receiver stopped normally (exit code $exitCode)")
        Write-Host "`n🛑 Mirroring session ended." -ForegroundColor DarkGray
    }

    exit $exitCode

} catch {
    Log("ERROR: $($_.Exception.Message)", "ERROR")
    Write-Host "`n❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) {
        Log("Position: $($_.InvocationInfo.PositionMessage)", "DEBUG")
    }
    Write-Host ""
    Write-Host "💡 Troubleshooting tips:" -ForegroundColor Yellow
    Write-Host "   1. Run this script again without any flags to re-run setup"
    Write-Host "   2. Check that Apple Bonjour is installed and running"
    Write-Host "   3. Ensure your iPhone and PC are on the same Wi-Fi network"
    Write-Host "   4. Temporarily disable third-party firewalls/testing"
    Write-Host ""
    Write-Host "📋 Log file: $logFile" -ForegroundColor Yellow
    exit 1
}
