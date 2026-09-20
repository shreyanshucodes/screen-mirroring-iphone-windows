# Presentation Checklist

Use this checklist before a live demo:

1. Connect the PC and iPhone to the same Wi-Fi network.
2. Start the receiver five minutes before the presentation.
3. Confirm the PC name appears under **Control Center -> Screen Mirroring**.
4. Use `-Sync` for video playback or the default low-latency mode for demos.
5. Keep the iPhone unlocked and connected to power for long sessions.
6. Use `-ShareSafe` when sharing the mirror window in Teams, Zoom, or OBS.
7. Avoid DRM-protected playback, which may intentionally block AirPlay output.

For a clean demo profile:

```powershell
.\Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1 `
  -Name "Presentation PC" -Fullscreen -ShareSafe
```
