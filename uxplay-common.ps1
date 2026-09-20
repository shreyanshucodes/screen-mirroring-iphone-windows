<#
.SYNOPSIS
    Shared UxPlay discovery. Dot-sourced by start-airplay.ps1, doctor.ps1,
    airplay-ui.ps1 and setup.ps1.
.DESCRIPTION
    One copy of "where is the engine, and where are its GStreamer plugins",
    because that answer changes between UxPlay versions and used to be
    duplicated (and drift) across every script.

    Never hardcode the install layout. 1.72.x nests the engine under
    _internal\bin. We search the known roots -- including whatever the uninstall
    registry reports -- and derive the plugin directory from wherever the exe
    actually turned up.

    IMPORTANT -- the 1.x / 2.x split. uxplay-windows 2.x is a ground-up Qt6
    rewrite that links uxplay in as a *library*. Verified against the published
    2.0.0.1736 archive (all 170 zip entries read from its central directory):
    the only executables are uxplay-windows.exe, mDNSResponder.exe and
    uxplay-bluetooth-beacon.exe. There is NO uxplay.exe and no command line, so
    none of this repo's tuned flags exist there. Find-UxPlay therefore reports
    Kind='GuiOnly' for such an install rather than pretending nothing is
    installed, so callers can say something true.
#>

# Firewall rule identities live here so setup.ps1 (which creates them) and
# doctor.ps1 (which verifies them) cannot drift apart.
function Get-PCAirPlayPortRule {
    <#
    .SYNOPSIS
        The fixed-port inbound rules.
    .DESCRIPTION
        These only matter when the engine is started with -p / -Port; without it
        UxPlay takes an ephemeral port and the program-scoped rule is what does
        the work. Ports taken from the engine's own help (1.72, verified):

            -p        Use legacy ports UDP 6000:6001:7011 TCP 7000:7001:7100
            -p n      Use TCP and UDP ports n,n+1,n+2

        Note UDP 7011, not a 6000-6009 range. The old rule opened 6000-6009,
        which covers 6000 and 6001 but MISSES 7011 -- so the legacy-port mode
        was never fully permitted, in the one situation (a third-party firewall
        that ignores program rules) where these rules are the point.

        -LocalPort takes an ARRAY. Passing '7000,7001,7100' as one comma-separated
        string fails with "The port is invalid"; ranges like '6000-6009' are fine.
    #>
    @(
        @{ Name = 'PCAirPlay - Control (TCP)';        Protocol = 'TCP'; Port = @('7000', '7001', '7100') }
        @{ Name = 'PCAirPlay - RTP streams (UDP)';    Protocol = 'UDP'; Port = @('6000-6009', '7011') }
        @{ Name = 'PCAirPlay - mDNS discovery (UDP)'; Protocol = 'UDP'; Port = @('5353') }
    )
}

function Get-PCAirPlayProgramRuleName { 'PCAirPlay - uxplay.exe (any port)' }

function Get-PCAirPlayLogDirectory { Join-Path $env:LOCALAPPDATA 'pcairplay' }

function New-PCAirPlayLogPath {
    <#
    .SYNOPSIS
        A timestamped log path under %LOCALAPPDATA%\pcairplay, oldest pruned.
    .DESCRIPTION
        Shared so the CLI and the UI write to ONE place - a user asked to "send
        the log" should not have to know which launcher produced the session.

        Prunes BEFORE returning, so the file the caller is about to write is
        never itself a rotation candidate.
    #>
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [int]$Keep = 5
    )
    $dir = Get-PCAirPlayLogDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $dir -Filter "$Prefix-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Join-Path $dir "$Prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

function Get-FirewallRuleState {
    <#
    .SYNOPSIS
        'Missing' / 'Disabled' / 'Enabled' for a rule DisplayName.
    .DESCRIPTION
        .Enabled is a NetSecurity enum, not a string. Comparing it to 'True' does
        work in PS 5.1 - verified against a real enabled rule and a real disabled
        one, the string is coerced to the enum - but it reads like a string test
        and fails open: '-eq ''Yes''' returns False instead of throwing. ToString()
        makes the intent explicit and cannot be misread.

        Also collapses duplicates. -DisplayName can return several rules, and an
        array on the left of -ne turns the comparison into a filter that is
        truthy whenever any element differs.

        Shared, because setup.ps1's VERIFY pass - the code whose whole job is to
        confirm the result - was doing the bare '$r.Enabled -eq ''True''' this
        function exists to replace, on an unwrapped Get-NetFirewallRule.
    #>
    param([string]$Name)

    $rules = @(Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return 'Missing' }
    if (@($rules | Where-Object { $_.Enabled.ToString() -eq 'True' }).Count -eq 0) { return 'Disabled' }
    'Enabled'
}

function Test-PCAirPlayPortOverlap {
    <#
    .SYNOPSIS
        Does a firewall rule's LocalPort touch any port AirPlay needs?
    .DESCRIPTION
        doctor.ps1 used to answer this with a hardcoded
        '5353','7000','7001','7100' list, which drifted from
        Get-PCAirPlayPortRule in two ways: it omitted UDP 7011 -- the very port
        the comment above says the old rule missed -- and the whole RTP range,
        so a BLOCK rule on either was invisible to the one check that exists to
        find block rules.

        Both sides can be ranges ('6000-6009') or 'Any', so this compares
        intervals rather than strings: '-in' against a list of single ports
        misses a block rule written as a range, which is how a human would
        most likely write one.

        Returns the matching ports as text, or $null for no overlap.
    #>
    param([string[]]$LocalPort)

    $toRange = {
        param([string]$Spec)
        if ($Spec -match '^(\d+)\s*-\s*(\d+)$') { [int]$Matches[1], [int]$Matches[2] }
        elseif ($Spec -match '^\d+$')           { [int]$Spec, [int]$Spec }
        else                                    { $null }   # 'Any', 'RPC', ...
    }

    $needed = foreach ($r in Get-PCAirPlayPortRule) {
        foreach ($p in $r.Port) { , (& $toRange $p) }
    }

    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($spec in @($LocalPort)) {
        # 'Any' blocks everything, including us. Report it rather than skip it.
        if ($spec -eq 'Any') { $hits.Add('any port'); continue }
        $r = & $toRange $spec
        if (-not $r) { continue }
        foreach ($n in $needed) {
            if ($n -and $r[0] -le $n[1] -and $n[0] -le $r[1]) { $hits.Add($spec); break }
        }
    }
    if ($hits.Count -gt 0) { ($hits | Select-Object -Unique) -join ', ' } else { $null }
}

function Get-BonjourSocketState {
    <#
    .SYNOPSIS
        Is the Bonjour service actually able to hear mDNS on the network?
    .DESCRIPTION
        "Bonjour Service is Running" is not enough. The engine registers through
        mDNSResponder, and mDNSResponder talks to the network through
        interface-bound UDP 5353 sockets. Those binds are first-come and can be
        exclusive: observed live on 2026-07-20, the Apple Devices app's helpers
        (AMPDevicesAgent, then AppleMobileDeviceLauncher - installed for the USB
        tether) held the LAN interface's :5353 socket while mDNSResponder held
        only loopback.
        The service was Running, the engine registered without error - and the
        PC was invisible to every iPhone on the LAN, while USB-tether sessions
        still worked, because that interface got fresh sockets each time the
        cable came up. "Wi-Fi doesn't work, cable does" was exactly this.

        States:
          NoService - Bonjour is not installed.
          Stopped   - installed but not running.
          Deaf      - running, but with NO network-facing UDP 5353 socket:
                      registrations succeed and nothing reaches the network.
          Listening - at least one non-loopback 5353 socket is Bonjour's.

        .Holders names other processes with non-loopback 5353 binds. A browser
        or svchost on 0.0.0.0 is normal shared coexistence; a PER-INTERFACE
        bind by something else is what starves mDNSResponder.

        The repair (elevated, one shot so Bonjour wins the re-bind race - the
        Apple helpers re-grab a freed port within seconds):
          Stop-Process -Name AMPDevicesAgent,AppleMobileDeviceLauncher -Force -ErrorAction SilentlyContinue; Restart-Service 'Bonjour Service'
        The helpers respawn harmlessly next time the iPhone is plugged in.
    #>
    $result = [pscustomobject]@{ State = 'NoService'; Endpoints = @(); Holders = @() }
    $svc = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
    if (-not $svc) { return $result }
    if ($svc.Status -ne 'Running') { $result.State = 'Stopped'; return $result }

    $svcPid = 0
    try {
        $svcPid = [int](Get-CimInstance Win32_Service -Filter "Name='Bonjour Service'" -ErrorAction Stop).ProcessId
    } catch { }
    if ($svcPid -eq 0) {
        # Cannot resolve the service PID, so "deaf" cannot be told apart from
        # "fine". Do not cry wolf on a query failure.
        $result.State = 'Listening'
        return $result
    }

    $udp = @(Get-NetUDPEndpoint -LocalPort 5353 -ErrorAction SilentlyContinue |
             Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' })
    $mine   = @($udp | Where-Object { $_.OwningProcess -eq $svcPid })
    $others = @($udp | Where-Object { $_.OwningProcess -ne $svcPid })

    $result.Endpoints = @($mine | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" })
    $result.Holders   = @($others | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        '{0} ({1}:{2})' -f $(if ($p) { $p.ProcessName } else { "pid $($_.OwningProcess)" }), $_.LocalAddress, $_.LocalPort
    } | Select-Object -Unique)
    $result.State = if ($mine.Count -gt 0) { 'Listening' } else { 'Deaf' }
    $result
}

function Get-UxPlayUninstallEntry {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*uxplay*' }
}

function Get-UxPlayInstallRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    function Add-Root([string]$path) {
        if (-not $path) { return }
        $p = $path.Trim().Trim('"').TrimEnd('\')
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { return }
        # Refuse anything that would turn the search below into a whole-drive
        # crawl. Some MSIs write the *parent* directory into InstallLocation.
        $bad = @($env:SystemDrive, "$env:SystemDrive\", $env:SystemRoot,
                 $env:ProgramFiles, ${env:ProgramFiles(x86)},
                 $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE) |
               Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
        if ($bad -contains $p) { return }
        if ($roots -notcontains $p) { $roots.Add($p) }
    }

    Add-Root "${env:ProgramFiles(x86)}\uxplay-windows"
    Add-Root "$env:ProgramFiles\uxplay-windows"
    Add-Root "$env:LOCALAPPDATA\Programs\uxplay-windows"

    # The MSI may install somewhere we didn't guess - ask Windows.
    foreach ($e in @(Get-UxPlayUninstallEntry)) { Add-Root $e.InstallLocation }

    # Plain array, NOT ",$roots.ToArray()": the unary comma's protection survives
    # the caller's @() wrap, so foreach would then iterate one String[] element
    # instead of the strings. Callers wrap in @() to normalise 0 and 1 results.
    $roots.ToArray()
}

function Get-UxPlayVersion {
    <#
    .SYNOPSIS
        DisplayVersion for the install that owns $ForPath, or the first entry.
    .DESCRIPTION
        Resolving the version independently of the located exe meant a second,
        stale install could supply the version string for a different one.
    #>
    param([string]$ForPath)

    $entries = @(Get-UxPlayUninstallEntry)
    if ($entries.Count -eq 0) { return $null }

    if ($ForPath) {
        foreach ($e in $entries) {
            $loc = $e.InstallLocation
            if ($loc) {
                $loc = $loc.Trim().Trim('"').TrimEnd('\')
                if ($loc -and $ForPath.StartsWith($loc, [StringComparison]::OrdinalIgnoreCase)) {
                    return $e.DisplayVersion
                }
            }
        }
    }
    ($entries | Select-Object -First 1).DisplayVersion
}

function Find-UxPlay {
    <#
    .SYNOPSIS
        Returns the installed UxPlay, or $null if nothing is installed.
    .OUTPUTS
        Kind      'Cli'     - uxplay.exe found; this repo can drive it.
                  'GuiOnly' - only uxplay-windows.exe (2.x Qt6 app). No command
                              line exists, so the launchers cannot use it.
        Exe       full path to uxplay.exe, or $null when Kind is 'GuiOnly'.
        GuiExe    full path to uxplay-windows.exe when present.
        BinDir / PluginDir / Version / Root
    #>
    $roots = @(Get-UxPlayInstallRoots)

    # Depth-capped: an unexpected root must never become a whole-drive crawl.
    $find = {
        param($name)
        $out = @()
        foreach ($r in $roots) {
            $out += @(Get-ChildItem -LiteralPath $r -Recurse -Depth 4 -Filter $name -File -ErrorAction SilentlyContinue)
        }
        $out
    }

    $exe = $null; $root = $null
    # Newest wins: an old install under Program Files (x86) used to shadow a
    # newer one simply because that root is probed first.
    $cliHits = @(& $find 'uxplay.exe') | Sort-Object LastWriteTimeUtc -Descending
    if ($cliHits.Count -gt 0) { $exe = $cliHits[0].FullName }

    $guiHits = @(& $find 'uxplay-windows.exe') | Sort-Object LastWriteTimeUtc -Descending
    $guiExe = if ($guiHits.Count -gt 0) { $guiHits[0].FullName } else { $null }

    if (-not $exe) {
        # An MSYS2 / manual build may just be on PATH.
        $cmd = Get-Command uxplay -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { $exe = $cmd.Source }
    }

    if (-not $exe -and -not $guiExe) { return $null }

    $kind   = if ($exe) { 'Cli' } else { 'GuiOnly' }
    $binDir = if ($exe) { Split-Path $exe -Parent } else { Split-Path $guiExe -Parent }
    foreach ($r in $roots) {
        if ($binDir.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $root = $r; break }
    }

    # Plugins live in a gstreamer-1.0 directory at or above the exe. Walk up,
    # but never past the install root -- an unbounded walk-up reached
    # C:\Program Files and took ~12 s, and could bind another app's plugins.
    $pluginDir = $null
    $ceiling = if ($root) { $root } else { $binDir }
    $base = $binDir
    for ($i = 0; $i -lt 4 -and $base; $i++) {
        $hit = Get-ChildItem -LiteralPath $base -Recurse -Depth 3 -Directory -Filter 'gstreamer-1.0' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $pluginDir = $hit.FullName; break }
        if ($base.TrimEnd('\') -eq $ceiling.TrimEnd('\')) { break }
        $parent = Split-Path $base -Parent
        if (-not $parent -or $parent -eq $base) { break }
        $base = $parent
    }

    [pscustomobject]@{
        Kind      = $kind
        Exe       = $exe
        GuiExe    = $guiExe
        BinDir    = $binDir
        PluginDir = $pluginDir
        Root      = $root
        Version   = Get-UxPlayVersion -ForPath $binDir
    }
}

function Get-UxPlayIncompatibleMessage {
    <#
    .SYNOPSIS
        The one explanation of the 2.x problem, so all four scripts say the same
        thing instead of each inventing wording.
    #>
    param($UxPlay)
    @(
        "UxPlay $(if ($UxPlay.Version) { $UxPlay.Version } else { '2.x' }) is installed, but it is the Qt6 rewrite,"
        "which links uxplay in as a library and ships no uxplay.exe and no command line."
        "These scripts drive the engine by command line, so they cannot use it."
        ""
        "Either use the 2.x app on its own (Start Menu -> uxplay-windows), or install"
        "the 1.72.1-3 build these scripts are built for:"
        "    powershell -ExecutionPolicy Bypass -File .\setup.ps1"
    ) -join "`n"
}

function Resolve-UxPlayDeviceName {
    <#
    .SYNOPSIS
        Normalise the advertised device name, once, for every entry point.
    .DESCRIPTION
        PowerShell 5.1 builds a native command line by naive quoting: an embedded
        '"' is dropped and a trailing '\' escapes the closing quote. Either
        destroys the argument boundary and swallows the NEXT element of the array
        - verified with a printargs harness, a name of 'Demo"s PC' delivers
        argv[1] = 'Demos PC -nh -nc', so -nh never reaches the engine, the
        advertised name is wrong, and nothing reports a problem.

        A name that begins with '-' is rejected rather than repaired: uxplay
        reads it as another option and reports it as a MISSING argument
        ('*** ERROR: invalid: "-n" had no argument'), which sends the user off
        looking for a broken install.

        Returns an object rather than a string so the caller decides how to
        present the outcome - the CLI writes to the console and exits, the UI
        shows a MessageBox and refuses to start.
    #>
    param([string]$Name)

    $clean = ($Name -replace '"', '') -replace '^\s+', '' -replace '[\s\\]+$', ''
    if (-not $clean) { $clean = 'PC' }

    $err = $null
    if ($clean.StartsWith('-')) {
        $err = @(
            "The device name cannot start with '-'."
            "uxplay would read it as another option and report:"
            '    *** ERROR: invalid: "-n" had no argument'
            "Try 'Demo' instead."
        ) -join "`n"
    }

    [pscustomobject]@{
        Name    = $clean
        Changed = ($clean -ne $Name)
        Error   = $err
    }
}

function Build-UxPlayArgs {
    <#
    .SYNOPSIS
        The one place the engine's argument vector is constructed.
    .DESCRIPTION
        start-airplay.ps1 and airplay-ui.ps1 used to build this independently and
        drifted: the UI wired -Fps into the '@r' half of '-s wxh@r', so choosing
        "30 fps" also asked the phone for a 30 Hz DISPLAY MODE - a different
        request from capping the stream at 30 fps - and the UI could reach
        neither -ShareSafe, -NoAudio, -SoftwareDecode nor the port flags at all.

        Every flag emitted here was checked against "uxplay -h" for 1.72.1-3.

        Returns .Args (the token array) and .Notes (caller-displayable strings),
        because the sink fallback has something to say and this function must not
        assume a console exists to say it in.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Resolution = '1920x1080',
        [int]$RefreshRate = 60,
        [int]$Fps = 60,
        [string]$PluginDir,
        [switch]$Sync,
        [switch]$Fullscreen,
        [switch]$Pin,
        [ValidatePattern('^$|^\d{4}$')][string]$PinCode,
        [switch]$SoftwareDecode,
        [switch]$ShareSafe,
        [switch]$NoAudio,
        [int]$Port,
        [switch]$LegacyPorts,
        [switch]$EngineDebug
    )

    $notes = New-Object System.Collections.Generic.List[string]
    $hasPlugin = {
        param([string]$Dll)
        $PluginDir -and (Test-Path -LiteralPath (Join-Path $PluginDir $Dll))
    }

    $argList = @(
        '-n', $Name
        '-nh'                               # don't append "@hostname" to the display name
        '-s', "$Resolution@$RefreshRate"    # "@r" is the requested display REFRESH RATE...
        '-fps', $Fps                        # ...and this is the separate framerate cap
        '-nc'                               # keep the window open when the phone disconnects
        '-nohold'                           # let a new phone take over from the current one
    )

    if ($Sync) {
        $argList += '-vsync'                # correct lip-sync, higher latency
    } else {
        $argList += @('-vsync', 'no')       # lowest latency - best for interactive demos
    }

    # -h265 sets AirPlay features bit 42 (SupportsScreenMultiCodec). Without
    # it, a phone that decides to send H.265 - reliably at 4K, and observed
    # live at 1440p from an iPhone16,1 on iOS 26.5.2 (AirPlay/950.7.1) - has
    # its video REJECTED: the engine logs "received type 0x01 packet with no
    # payload ... use startup option -h265" and closes the connection, while
    # the phone keeps showing the mirroring tickmark. That was the documented
    # "connected but no video" stall, root-caused 2026-07-20 from the first
    # captured engine log of a stalled session. H.265 decode rides the same
    # d3d11/nvcodec plugins as H.264 on this build, so this is unconditional.
    $argList += '-h265'

    # Prefer the Direct3D 11 sink: hardware-accelerated presentation on Windows
    # and the only sink here that supports -fs properly.
    #
    # -ShareSafe swaps it for the OpenGL sink. d3d11videosink can present through
    # a hardware overlay / flip-model swapchain, and a window drawn that way is
    # capable of capturing as a BLACK RECTANGLE in a conferencing app's "share a
    # window" mode - the mirror looks perfect on this PC and is black to everyone
    # on the call. glimagesink draws into the window the ordinary way, which every
    # capture path can read, at the cost of hardware presentation.
    if ($ShareSafe -and (& $hasPlugin 'libgstopengl.dll')) {
        $argList += @('-vs', 'glimagesink')
    } else {
        if ($ShareSafe) {
            $notes.Add("Share-safe mode was requested but the OpenGL plugin is missing; keeping the D3D11 sink.")
        }
        if (& $hasPlugin 'libgstd3d11.dll') { $argList += @('-vs', 'd3d11videosink') }
    }

    if ($NoAudio) {
        $argList += @('-as', '0')
    } elseif (& $hasPlugin 'libgstwasapi.dll') {
        $argList += @('-as', 'wasapisink')
    }

    # -p and -p n are different modes, not a value and its default: bare -p means
    # the legacy fixed set, -p n means n,n+1,n+2 on both TCP and UDP.
    if ($LegacyPorts) { $argList += '-p' }
    elseif ($Port)    { $argList += @('-p', $Port) }
    # -fs is passed unconditionally on purpose. uxplay honours it on D3D11/X11/
    # Wayland/VAAPI/kms and ignores it elsewhere; whether autovideosink lands on
    # d3d11videosink cannot be decided from the presence of a DLL filename, so
    # gating this on the probe above would suppress fullscreen that in fact works.
    if ($Fullscreen)     { $argList += '-fs' }
    # -reg is what makes a PIN stick: without it the register file is never
    # written and the phone is challenged again on every single connection.
    #
    # A fixed code must be a SEPARATE token: the engine's help reads
    # "-pin[xxxx]", but "-pin1234" is rejected as an unknown option, while
    # "-pin 1234" is accepted (both verified live on 1.72.1-3). The fixed form
    # exists so a caller with a UI can KNOW the PIN and display it, instead of
    # sending the user to a console window to read a random one.
    if ($PinCode)        { $argList += @('-pin', $PinCode, '-reg') }
    elseif ($Pin)        { $argList += @('-pin', '-reg') }
    if ($SoftwareDecode) { $argList += '-avdec' }
    # "-d 1" = uxplay's own debug logging with packet data skipped. This is the
    # capture tool for the open stall issue: it shows the exact RTSP request
    # where negotiation stops, which the default verbosity does not.
    if ($EngineDebug)    { $argList += @('-d', '1') }

    [pscustomobject]@{
        Args  = $argList
        Notes = @($notes)
    }
}

function Initialize-UxPlayEnvironment {
    <#
    .SYNOPSIS
        Puts the engine's own DLLs on PATH and points GStreamer at its plugins.
    .DESCRIPTION
        Without GST_PLUGIN_PATH the engine starts and then shows no video,
        because the sinks and decoders silently fail to load. This is the most
        common cause of a "it runs but the window is black" report.
    #>
    param([Parameter(Mandatory)]$UxPlay)

    if ($UxPlay.BinDir -and ($env:PATH -split ';') -notcontains $UxPlay.BinDir) {
        $env:PATH = "$($UxPlay.BinDir);$env:PATH"
    }
    if ($UxPlay.PluginDir) { $env:GST_PLUGIN_PATH = $UxPlay.PluginDir }

    # UxPlay keeps its key pair (.uxplay.pem) and PIN register (.uxplay.register)
    # under $HOME, which Windows does not define. Without it the engine logs
    # "could not determine $HOME: public key will not be saved" and regenerates
    # its AirPlay identity on every launch, so a paired phone re-prompts.
    if (-not $env:HOME -and $env:USERPROFILE) { $env:HOME = $env:USERPROFILE }
}

function Get-LanIPAddress {
    <#
    .SYNOPSIS
        The single IPv4 address on the adapter that actually routes off-box.
    .DESCRIPTION
        "First IPv4 address" is wrong when a VPN or Hyper-V adapter is present.
        Order by interface metric (lowest = preferred route) so the answer is
        deterministic, and always return ONE string: member enumeration returns
        an array when an adapter carries more than one IPv4, which silently
        broke every caller that string-compared the result.
    #>
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
           Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
           Sort-Object @{ Expression = { $_.NetIPv4Interface.InterfaceMetric } },
                       @{ Expression = { $_.NetAdapter.ifIndex } } |
           Select-Object -First 1

    $ip = @($cfg.IPv4Address.IPAddress) | Select-Object -First 1

    if (-not $ip) {
        $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Sort-Object InterfaceMetric |
                Select-Object -ExpandProperty IPAddress) | Select-Object -First 1
    }
    if ($ip) { [string]$ip } else { $null }
}

function Get-CompetingReceiverProcess {
    <#
    .SYNOPSIS
        Other AirPlay receivers running on this PC.
    .DESCRIPTION
        A second receiver is not just a port clash: it also advertises over
        mDNS, so the phone lists two devices and the wrong one gets tapped.
        uxplay-windows is included deliberately -- the 2.x app is a full
        receiver in its own right and the installer puts it in the Start Menu.

        The pattern is a local constant on purpose. As a $script: variable it
        would resolve to $null if this file were ever dot-sourced into a scope
        the function does not close over, and "-match ''" matches EVERY process,
        which would offer to kill everything running on the machine.
    #>
    param([int[]]$ExcludeId = @())

    $pattern = '^(pigeoncast|AirServer|Reflector.*|AirMyPC|LonelyScreen|X-Mirage|uxplay-windows)$'
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -notin $ExcludeId -and $_.ProcessName -match $pattern }
}

function Get-UxPlayEngineProcess {
    <#
    .SYNOPSIS
        Running uxplay.exe engine processes (exact name match, no wildcard).
    #>
    param([int[]]$ExcludeId = @())
    Get-Process -Name 'uxplay' -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -notin $ExcludeId }
}

# --- Framed-mirror coupling -------------------------------------------------
# The framed view (frame-mirror.ps1) is its own process, single-instance
# behind a named mutex. These helpers are how the other entry points see and
# control it without holding a PID. NOTE: frame-mirror.ps1 dot-sources this
# file under Set-StrictMode 3, so anything it calls from here must stay
# strict-clean.

function Get-FramedMirrorMutexName   { 'Local\PCAirPlay-FramedMirror' }
function Get-FramedMirrorWindowTitle { 'AirPlayPC - Framed Mirror' }

function Initialize-PCAirPlayNative {
    <#
    .SYNOPSIS
        Compile the small user32 interop type on first use. $true when usable.
    .DESCRIPTION
        Lazy, because Add-Type compiles C# at runtime: the CLI and doctor never
        need it, and it can fail on a locked-down %TEMP%. Guarded by a type
        probe, because compiling the same type name twice in one session
        throws. Callers must treat $false as "degrade politely", never as an
        error worth a dialog.
    #>
    if ('PCAirPlayNative' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PCAirPlayNative
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    public const uint WM_CLOSE = 0x0010;
    public const int SW_RESTORE = 9;

    // Call THIS from PowerShell, never FindWindow(null, ...): PowerShell
    // converts $null to "" when binding a string parameter, so the search
    // becomes "class name is empty string" and matches nothing - silently.
    // Cost a live debugging round; a C# null is the real null.
    public static IntPtr FindWindowByTitle(string title) { return FindWindow(null, title); }
}
'@
        $true
    } catch { [bool]('PCAirPlayNative' -as [type]) }
}

function Test-FramedMirrorRunning {
    <#
    .SYNOPSIS
        Is a framed-mirror instance alive? Probes its single-instance mutex.
    .DESCRIPTION
        The mutex outlives any particular window state (waiting, attached,
        mid-startup), so this cannot be fooled the way a window-title search
        can. An access-denied probe means the mutex EXISTS - held by an
        elevated instance - which is still "running" for every caller here.
    #>
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting((Get-FramedMirrorMutexName))
        $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $false
    } catch {
        $true
    } finally {
        if ($m) { $m.Dispose() }
    }
}

function Close-FramedMirrorWindow {
    <#
    .SYNOPSIS
        Ask a running framed mirror to close, gracefully, and wait briefly.
    .DESCRIPTION
        WM_CLOSE to the bezel window runs the frame's own Closing handler,
        which detaches and RESTORES the engine's video window first. Never
        kill the frame's process instead: while attached, the video window is
        OWNED by the bezel, and Windows destroys owned windows with their
        owner - a hard kill tears down the live mirror session with it
        (observed live; see CLAUDE.md).

        Returns $true when no frame remains (none was running, or it closed
        within the timeout); $false when one is still there.
    #>
    param([int]$TimeoutMs = 2500)

    if (-not (Test-FramedMirrorRunning)) { return $true }
    if (-not (Initialize-PCAirPlayNative)) { return $false }

    $title = Get-FramedMirrorWindowTitle
    $h = [PCAirPlayNative]::FindWindowByTitle($title)
    if ($h -eq [IntPtr]::Zero) {
        # Mutex held but no window yet: a frame still starting up. One retry
        # beat, then report honestly rather than spin.
        Start-Sleep -Milliseconds 400
        $h = [PCAirPlayNative]::FindWindowByTitle($title)
        if ($h -eq [IntPtr]::Zero) { return (-not (Test-FramedMirrorRunning)) }
    }
    [void][PCAirPlayNative]::PostMessage($h, [PCAirPlayNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not [PCAirPlayNative]::IsWindow($h) -and -not (Test-FramedMirrorRunning)) { return $true }
        Start-Sleep -Milliseconds 120
    }
    (-not (Test-FramedMirrorRunning))
}

function Show-PCAirPlayUiWindow {
    <#
    .SYNOPSIS
        Bring an existing UI window to the foreground. $true if one was found.
    .DESCRIPTION
        The UI is single-instance; a second launch calls this and exits, so a
        double-clicked launcher surfaces the window that already exists
        instead of stacking a twin on top of it.
    #>
    param([string]$Title = 'AirPlayPC')
    if (-not (Initialize-PCAirPlayNative)) { return $false }
    $h = [PCAirPlayNative]::FindWindowByTitle($Title)
    if ($h -eq [IntPtr]::Zero) { return $false }
    if ([PCAirPlayNative]::IsIconic($h)) {
        [void][PCAirPlayNative]::ShowWindow($h, [PCAirPlayNative]::SW_RESTORE)
    }
    [void][PCAirPlayNative]::SetForegroundWindow($h)
    $true
}
