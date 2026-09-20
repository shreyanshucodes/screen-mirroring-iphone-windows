# Screen Mirroring for iPhone on Windows

A focused launcher for this project. It starts UxPlay with sensible defaults so
an iPhone can mirror through the native iOS Screen Mirroring menu.

This is a wrapper, not a new AirPlay implementation. The repository includes
the installer and shared PowerShell functions it needs.

## Requirements

- Windows 10 or 11
- PowerShell 5.1
- The complete repository, not just this folder
- Administrator access for first-time setup
- iPhone and PC on the same local network
- Apple Bonjour and the UxPlay Windows build, installed by `setup.ps1`

## Quick start

From the root of this repository, open PowerShell as
Administrator and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1
```

Then open Control Center on the iPhone, tap **Screen Mirroring**, and select
`My PC`.

For normal use after setup, run the script without Administrator privileges:

```powershell
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Name "My Laptop"
```

## Options

```powershell
# Presentation mode with a custom name and PIN
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 `
  -Name "Presentation PC" -PIN -Fullscreen

# Video playback mode
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Sync

# Reduce load on a busy network
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -Fps 30

# Make the window easier for Teams, Zoom, or recording software to capture
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 -ShareSafe
```

Available switches are `-Name`, `-PIN`, `-Fullscreen`, `-Sync`, `-Fps`,
`-NoAudio`, `-ShareSafe`, `-SoftwareDecode`, `-EngineDebug`, and `-SkipSetup`.

## Troubleshooting

- If the PC does not appear on the iPhone, verify Bonjour is running and both
  devices are on the same network.
- If first-time setup fails, rerun `setup.ps1` from an elevated PowerShell.
- If video is black, try `-SoftwareDecode`.
- If screen sharing in Teams or Zoom is black, try `-ShareSafe`.
- Logs are written by the parent project under `%LOCALAPPDATA%\pcairplay`.

## Scope and licensing

The wrapper scripts are MIT licensed. UxPlay, the Windows build, and Bonjour
remain third-party components with their own licenses. See
`THIRD-PARTY-NOTICES.md` and the parent repository documentation before
redistributing a packaged build.
