<#
.SYNOPSIS
    One-time setup for the AirPlayPC receiver. Run as Administrator.
.DESCRIPTION
    Installs the UxPlay engine, verifies the mDNS responder it depends on, and
    opens the firewall so an iPhone can discover and mirror to this PC.

    Every system change is announced before it happens. Use -WhatIf to preview.

    WHICH BUILD, AND WHY IT IS NOT THE LATEST ONE
    uxplay-windows 2.x is a ground-up Qt6 rewrite that links uxplay in as a
    library. Verified against the published 2.0.0.1736 archive (all 170 zip
    entries read from its central directory): its only executables are
    uxplay-windows.exe, mDNSResponder.exe and uxplay-bluetooth-beacon.exe.
    There is no uxplay.exe and no command line, so none of the tuned flags these
    scripts rely on exist there. This script therefore installs the newest 1.x
    release (1.72.1-3), and refuses 2.x rather than leaving you with an engine
    the launchers cannot drive. Use the 2.x app standalone if you want it.
.PARAMETER SetNetworkPrivate
    Set the active network profile to Private. mDNS discovery is blocked on
    Public profiles by default, which is a common reason the PC never appears in
    the iPhone's Screen Mirroring list.
.PARAMETER SkipInstall
    Skip the install step entirely (e.g. UxPlay already installed manually).
.PARAMETER UseWinget
    Install from winget instead of the GitHub release. The winget package
    leapbtw.uxplay is pinned to 1.72.1.3, which is the same generation this
    script targets anyway, so this is a fine fallback rather than a downgrade.
.PARAMETER Tag
    Install a specific GitHub release tag instead of the newest 1.x. Use only if
    you know what you are doing; 2.x tags are rejected.
.PARAMETER AnyRemoteAddress
    Scope the firewall rules to any remote address instead of the local subnet.
    The default (LocalSubnet) is correct: AirPlay cannot work off-subnet because
    mDNS does not route, so a wider scope only adds exposure.
.PARAMETER Uninstall
    Remove the firewall rules this script created - and nothing else. UxPlay and
    Apple Bonjour were installed system-wide by their own installers and keep
    their own entries in Apps & Features; logs and UI settings under
    %LOCALAPPDATA%\pcairplay are left for you to delete by hand. Idempotent, and
    -WhatIf previews it. The pcairplay installer's uninstaller runs this.
.PARAMETER SkipBonjourCheck
    Treat a missing Apple Bonjour as a warning instead of a failure. For CI and
    unattended image builds only: it skips the check, not the requirement - the
    receiver cannot be discovered by any iPhone until Bonjour is installed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SetNetworkPrivate,
    [switch]$SkipInstall,
    [switch]$UseWinget,
    [string]$Tag,
    [switch]$AnyRemoteAddress,
    [switch]$Uninstall,
    [switch]$SkipBonjourCheck
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'uxplay-common.ps1')

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "    [XX] $m" -ForegroundColor Red }
function Write-Note { param($m) Write-Host "         $m" -ForegroundColor Gray }

$script:failed = 0
$script:InstallSource = 'none'

# --- Elevation check -------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# A preview changes nothing, so do not make people elevate just to read it.
if (-not $isAdmin -and $WhatIfPreference) {
    Write-Warn "Not elevated - fine for -WhatIf, but a real run needs Administrator."
} elseif (-not $isAdmin) {
    Write-Bad "This script must run as Administrator (firewall + service changes)."
    Write-Host "    Right-click PowerShell -> Run as Administrator, then re-run:"
    Write-Host "      powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Gray
    exit 1
}

# --- Uninstall mode --------------------------------------------------------
# Removes what setup.ps1 itself created: the four firewall rules. UxPlay and
# Apple Bonjour arrived via their own installers and keep their own Apps &
# Features entries - removing them here would be a surprise, so this only
# points at them. Absent rules are reported, not treated as errors, so the
# installer's uninstaller can run this unconditionally.
if ($Uninstall) {
    Write-Step "Removing AirPlayPC firewall rules"

    $ruleNames = @((Get-PCAirPlayPortRule).Name) + @(Get-PCAirPlayProgramRuleName)
    foreach ($n in $ruleNames) {
        $existing = Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Ok "Already absent: $n"
            continue
        }
        if ($PSCmdlet.ShouldProcess($n, 'Remove firewall rule')) {
            try {
                $existing | Remove-NetFirewallRule -ErrorAction Stop
                Write-Ok "Removed: $n"
            } catch {
                Write-Bad "FAILED to remove '$n': $($_.Exception.Message)"
                $script:failed++
            }
        }
    }

    Write-Step "Left in place (on purpose)"
    Write-Note "UxPlay and Apple Bonjour have their own uninstallers: Settings -> Apps."
    Write-Note "Logs and UI settings live in $(Get-PCAirPlayLogDirectory) - delete that"
    Write-Note "folder by hand if you want them gone."
    Write-Note "If setup ever set a network profile to Private for you and you want"
    Write-Note "Public back: Set-NetConnectionProfile -InterfaceIndex <n> -NetworkCategory Public"

    if ($WhatIfPreference) {
        Write-Step "Preview complete - nothing was changed"
        exit 0
    }
    if ($script:failed -gt 0) {
        Write-Step "Uninstall finished with $script:failed problem(s)"
        exit 1
    }
    Write-Step "Firewall rules removed"
    exit 0
}

# PS 5.1 inherits .NET's default protocol list, which on some machines still
# excludes TLS 1.2. The GitHub API requires it, and the failure is an opaque
# "Could not create SSL/TLS secure channel" a long way from the cause.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- 1. UxPlay ------------------------------------------------------------
Write-Step "Installing UxPlay (AirPlay receiver engine)"

function Get-TargetRelease {
    <#
    .SYNOPSIS
        Newest release this repo can actually drive, i.e. the newest 1.x.
    .DESCRIPTION
        Deliberately NOT /releases/latest. That resolves to 2.0.0.1736, which
        ships no uxplay.exe -- installing it makes every launcher report
        "UxPlay is not installed" while an install plainly exists.
    #>
    $api = 'https://api.github.com/repos/leapbtw/uxplay-windows/releases'
    Write-Note "Querying releases..."
    # Anonymous API calls rate-limit by source IP, which bites shared CI
    # runners. A token, when one is in the environment, lifts that; the asset
    # download itself is unauthenticated either way.
    $headers = @{ 'User-Agent' = 'pcairplay-setup' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $all = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30

    if ($Tag) {
        $rel = $all | Where-Object { $_.tag_name -eq $Tag } | Select-Object -First 1
        if (-not $rel) { throw "No release tagged '$Tag'. Available: $(($all.tag_name) -join ', ')" }
        if ($rel.tag_name -match '^2\.') {
            throw "Release $Tag is a 2.x build. It ships no uxplay.exe and no command line, so these scripts cannot drive it."
        }
        return $rel
    }

    # Stable 1.x only. Sorting by tag would put '1.72-2' after '1.72.1-3'
    # lexically, so order by publish date instead.
    $rel = $all |
           Where-Object { -not $_.prerelease -and -not $_.draft -and $_.tag_name -match '^1\.' } |
           Sort-Object { [datetime]$_.published_at } -Descending |
           Select-Object -First 1
    if (-not $rel) { throw "No stable 1.x release found. Use -UseWinget." }
    $rel
}

function Install-FromGitHub {
    $rel = Get-TargetRelease

    # 1.x ships a single Inno Setup .exe. Keep the .msi branch for forward
    # compatibility, but exclude arm64 unless this machine is arm64.
    $isArm = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'
    $candidates = @($rel.assets | Where-Object {
        if ($_.name -notmatch '\.(msi|exe)$') { return $false }
        if ($isArm) { $_.name -match 'arm64' } else { $_.name -notmatch 'arm64' }
    })
    $asset = $candidates | Where-Object { $_.name -match 'installer' } | Select-Object -First 1
    if (-not $asset) { $asset = $candidates | Select-Object -First 1 }
    if (-not $asset) {
        throw "No .msi/.exe installer asset for this architecture in release $($rel.tag_name). Assets were: $(($rel.assets.name) -join ', ')"
    }

    $sizeMb = [math]::Round($asset.size / 1MB)
    Write-Note "Release $($rel.tag_name) -> $($asset.name) (${sizeMb} MB)"

    # Never join a remote-controlled name straight onto a path.
    $leaf = Split-Path $asset.name -Leaf
    if ($leaf -ne $asset.name -or $leaf -match '[\\/:*?"<>|]') {
        throw "Refusing to use asset name '$($asset.name)' as a filename."
    }
    $dest = Join-Path $env:TEMP $leaf

    Write-Note "Downloading (large file, allow a few minutes)..."
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the progress bar
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 900
    } finally {
        $ProgressPreference = $oldPref
    }

    try {
        $got = (Get-Item $dest).Length
        if ($got -ne $asset.size) {
            throw "Download incomplete: got $got bytes, expected $($asset.size)."
        }

        # A length check proves nothing about authenticity. Upstream binaries
        # are unsigned, so Authenticode verification is not an option here.
        # Defense in two layers: a hardcoded pin for the build this repo
        # targets (an attacker who swaps the asset controls the API digest
        # too, so the digest alone proves only self-consistency), then the
        # API digest for any newer 1.x this script may pick up later.
        $knownSha = @{
            # Verified 2026-07-20 against the live 1.72.1-3 release.
            'uxplay-windows-installer-v1.72.1-3.exe' = 'cb45de36d960b27d60dfe16a2a45489bd287d4335d37967f109d8cc4b5372986'
        }
        $apiSha = $null
        if ($asset.PSObject.Properties['digest'] -and $asset.digest) {
            $apiSha = ($asset.digest -replace '^sha256:', '').ToLowerInvariant()
        }
        $sha = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($knownSha.ContainsKey($leaf)) {
            if ($sha -ne $knownSha[$leaf]) { throw "SHA256 mismatch against the pinned known-good hash: got $sha, expected $($knownSha[$leaf])." }
            Write-Ok "SHA256 verified against the pinned known-good hash."
        } elseif ($apiSha) {
            if ($sha -ne $apiSha) { throw "SHA256 mismatch: got $sha, expected $apiSha." }
            Write-Ok "SHA256 verified against the GitHub asset digest."
            Write-Warn "No pinned hash for '$leaf' (newer release than this script knows) - only the API digest was checked."
        } else {
            Write-Warn "GitHub published no digest for this asset; only the byte count was checked."
        }

        Write-Note "Running installer silently..."
        if ($leaf -like '*.msi') {
            $p = Start-Process -FilePath 'msiexec.exe' `
                               -ArgumentList '/i', "`"$dest`"", '/qn', '/norestart' -PassThru
        } else {
            $p = Start-Process -FilePath $dest `
                               -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
        }

        # NOT -Wait: an Inno installer waits for its own [Run] entries, and if
        # the vendor's includes launching its GUI app without skipifsilent,
        # "silent install" quietly becomes "blocked forever behind a window
        # nobody can see". Poll instead: close any GUI the installer spawned
        # (it is a competing receiver here anyway - Get-CompetingReceiverProcess
        # lists uxplay-windows for that reason), and give up loudly after 10
        # minutes rather than hanging setup.
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while (-not $p.HasExited) {
            if ([DateTime]::UtcNow -gt $deadline) {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                throw "Installer did not finish within 10 minutes - killed. Re-run, or install manually."
            }
            Get-Process -Name 'uxplay-windows' -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
        # One more sweep: a GUI launched in the installer's last moments would
        # otherwise survive as a rival receiver with its own mDNS entry.
        Get-Process -Name 'uxplay-windows' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        # 3010 = success, reboot required. 1618 = another install in progress.
        switch ($p.ExitCode) {
            0     { }
            3010  { Write-Warn "Installer requests a reboot (exit 3010); the install itself succeeded." }
            1618  { throw "Another installation is already in progress (1618). Close it and re-run." }
            1603  { throw "Installer failed with 1603 (fatal error during installation)." }
            default { throw "Installer exited with $($p.ExitCode)." }
        }
    } finally {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }

    $script:InstallSource = "github:$($rel.tag_name)"
    Write-Ok "UxPlay $($rel.tag_name) installed from GitHub."
}

function Install-FromWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available on this machine."
    }
    winget install --id leapbtw.uxplay --exact `
        --accept-package-agreements --accept-source-agreements
    # winget exits 0 on success, or -1978335135 when already installed.
    if ($LASTEXITCODE -eq 0) {
        $script:InstallSource = 'winget'
        Write-Ok "UxPlay installed via winget."
    } elseif ($LASTEXITCODE -eq -1978335135) {
        $script:InstallSource = 'winget'
        Write-Ok "UxPlay already present, nothing to do."
    } else {
        throw "winget exited with $LASTEXITCODE."
    }
}

if ($SkipInstall) {
    Write-Warn "Skipped by request (-SkipInstall)."
    $script:InstallSource = 'skipped'
} elseif ($PSCmdlet.ShouldProcess('UxPlay', 'install')) {
    if ($UseWinget) {
        try {
            Install-FromWinget
        } catch {
            Write-Bad $_.Exception.Message
            Write-Note "Install manually from: https://github.com/leapbtw/uxplay-windows/releases"
            exit 1
        }
    } else {
        try {
            Install-FromGitHub
        } catch {
            # Say plainly what was lost. The old version swallowed this and left
            # every later message asserting things that were no longer true.
            Write-Warn "GitHub install failed: $($_.Exception.Message)"
            Write-Warn "Falling back to winget (leapbtw.uxplay, pinned to 1.72.1.3 - same generation)."
            try {
                Install-FromWinget
            } catch {
                Write-Bad $_.Exception.Message
                Write-Note "Install manually from:"
                Write-Note "  https://github.com/leapbtw/uxplay-windows/releases/tag/1.72.1-3"
                Write-Note "Pick uxplay-windows-installer-v1.72.1-3.exe - NOT a 2.x release."
                exit 1
            }
        }
    }
}

# Resolve once, after the install, and reuse.
$ux = Find-UxPlay

if ($ux -and $ux.Kind -eq 'GuiOnly') {
    Write-Bad "Only the 2.x GUI app is installed - there is no engine for these scripts to drive."
    Write-Host ((Get-UxPlayIncompatibleMessage -UxPlay $ux) -split "`n" | ForEach-Object { "      $_" }) -Separator "`n" -ForegroundColor Gray
    Write-Note "Uninstall it, then re-run this script to get the 1.72.1-3 build."
    $script:failed++
}

# --- 2. mDNS responder ----------------------------------------------------
# This is a hard dependency, not a nicety, and the repo used to say otherwise.
# Verified on the 1.72.1-3 engine: uxplay.exe imports dnssd.dll and calls
# DNSServiceRegister -- that is Apple's Bonjour SDK. Only the 2.x rewrite
# compiles in its own mDNSResponder, and 2.x has no CLI. So on the build these
# scripts use, no Bonjour means no advertisement and the PC never appears.
Write-Step "Checking mDNS responder (Apple Bonjour)"

$dnssd = "$env:SystemRoot\System32\dnssd.dll"
$bonjour = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue

if (-not $bonjour -and -not (Test-Path $dnssd)) {
    if ($SkipBonjourCheck) {
        Write-Warn "Apple Bonjour is not installed - accepted for now (-SkipBonjourCheck)."
        Write-Note "Mirroring cannot work without it. Install 'Bonjour Print Services for"
        Write-Note "Windows' before relying on this receiver: https://support.apple.com/kb/DL999"
    } else {
        Write-Bad "Apple Bonjour is not installed - UxPlay 1.72 cannot advertise without it."
        Write-Note "The engine links dnssd.dll and calls DNSServiceRegister; without Bonjour"
        Write-Note "the receiver starts but never appears on the iPhone."
        Write-Note "Install 'Bonjour Print Services for Windows': https://support.apple.com/kb/DL999"
        Write-Note "(iTunes installs it too, if you already have that.)"
        $script:failed++
    }
} else {
    if (Test-Path $dnssd) {
        $v = (Get-Item $dnssd).VersionInfo.FileVersion
        Write-Ok "Bonjour runtime present (dnssd.dll $v)."
    }
    if ($bonjour) {
        if ($bonjour.StartType -ne 'Automatic') {
            if ($PSCmdlet.ShouldProcess('Bonjour Service', 'Set startup type to Automatic')) {
                Set-Service -Name 'Bonjour Service' -StartupType Automatic
                Write-Ok "Startup type set to Automatic."
            }
        }
        if ($bonjour.Status -ne 'Running') {
            if ($PSCmdlet.ShouldProcess('Bonjour Service', 'Start service')) {
                Start-Service -Name 'Bonjour Service'
                Write-Ok "Bonjour started."
            }
        } else {
            Write-Ok "Bonjour Service is running."
        }
    } else {
        Write-Warn "dnssd.dll is present but the Bonjour Service is not registered."
        Write-Note "Reinstall Bonjour Print Services if discovery fails: https://support.apple.com/kb/DL999"
    }
}

# --- 3. Network profile ---------------------------------------------------
Write-Step "Checking network profile"
$publicProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.NetworkCategory -eq 'Public' })

if ($publicProfiles.Count -gt 0) {
    foreach ($p in $publicProfiles) {
        Write-Warn "'$($p.InterfaceAlias)' is on the Public profile - mDNS inbound is blocked."
    }
    if ($SetNetworkPrivate) {
        foreach ($p in $publicProfiles) {
            if ($PSCmdlet.ShouldProcess($p.InterfaceAlias, 'Set network category to Private')) {
                Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
                Write-Ok "'$($p.InterfaceAlias)' set to Private."
            }
        }
    } else {
        Write-Note "Not changing it. The explicit rules below cover the Public profile,"
        Write-Note "so this is usually fine. To change it anyway: setup.ps1 -SetNetworkPrivate"
    }
} else {
    Write-Ok "No adapters stuck on the Public profile."
}

# --- 4. Firewall ----------------------------------------------------------
Write-Step "Opening firewall ports for AirPlay"

# Scope to the local subnet by default. AirPlay cannot work off-subnet anyway
# (mDNS does not route), and the program rule below is an any-port inbound
# allow for reverse-engineered C that parses untrusted network input - there is
# no reason to expose that to arbitrary remote addresses on a Public profile.
$remote = if ($AnyRemoteAddress) { 'Any' } else { 'LocalSubnet' }
Write-Note "Remote address scope: $remote"

$rules = @(Get-PCAirPlayPortRule)

function Repair-RuleScope {
    <#
    .SYNOPSIS
        Narrow an existing rule's remote scope to what this run asked for.
    .DESCRIPTION
        Rules created before scoping existed are RemoteAddress=Any. Without this
        the hardening never reaches anyone who already ran setup once, and
        re-running it - the obvious thing to try - would silently change nothing.
    #>
    param($Rule, [string]$Name)

    $af = $Rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
    if (-not $af) { return }
    $cur = @($af.RemoteAddress)
    if ($remote -eq 'Any') { return }
    if ($cur.Count -eq 1 -and $cur[0] -eq $remote) { return }
    if ($cur -notcontains 'Any') { return }   # already narrowed to something

    if ($PSCmdlet.ShouldProcess($Name, "Narrow remote scope from Any to $remote")) {
        try {
            $af | Set-NetFirewallAddressFilter -RemoteAddress $remote -ErrorAction Stop
            Write-Ok "Narrowed remote scope to ${remote}: $Name"
        } catch {
            Write-Warn "Could not narrow scope on '$Name': $($_.Exception.Message)"
        }
    }
}

function Repair-RulePort {
    <#
    .SYNOPSIS
        Bring an existing rule's port list up to date with the spec.
    .DESCRIPTION
        The UDP rule originally opened 6000-6009, which misses UDP 7011 - one of
        the three legacy ports the engine actually uses. "Already present" is not
        the same as "correct", and a rule created by an older run would otherwise
        never be fixed no matter how often setup is re-run.
    #>
    param($Rule, $Spec)

    $pf = $Rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    if (-not $pf) { return }
    $cur  = @($pf.LocalPort) | Sort-Object
    $want = @($Spec.Port)    | Sort-Object
    if (-not (Compare-Object $cur $want)) { return }

    if ($PSCmdlet.ShouldProcess($Spec.Name, "Update ports from '$($cur -join ',')' to '$($want -join ',')'")) {
        try {
            $pf | Set-NetFirewallPortFilter -LocalPort $Spec.Port -ErrorAction Stop
            Write-Ok "Updated ports on '$($Spec.Name)': $($cur -join ',') -> $($want -join ',')"
        } catch {
            Write-Warn "Could not update ports on '$($Spec.Name)': $($_.Exception.Message)"
        }
    }
}

foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "Rule already present: $($r.Name)"
        Repair-RulePort  -Rule $existing -Spec $r
        Repair-RuleScope -Rule $existing -Name $r.Name
        continue
    }
    if ($PSCmdlet.ShouldProcess($r.Name, 'Create inbound allow rule')) {
        # Report what actually happened rather than assuming success - an earlier
        # version printed "Created" even when the call had failed.
        try {
            New-NetFirewallRule `
                -DisplayName $r.Name `
                -Direction Inbound `
                -Action Allow `
                -Protocol $r.Protocol `
                -LocalPort $r.Port `
                -RemoteAddress $remote `
                -Profile Domain,Private,Public `
                -Description 'Allows an iPhone to discover and mirror to this PC via AirPlay.' `
                -ErrorAction Stop | Out-Null
            Write-Ok "Created: $($r.Name)  ($($r.Protocol) $($r.Port -join ','))"
        } catch {
            Write-Bad "FAILED to create '$($r.Name)': $($_.Exception.Message)"
        }
    }
}

# The program-scoped rule is the load-bearing one: started without -p, UxPlay
# takes an ephemeral port and publishes it over mDNS, so the fixed port rules
# above cover nothing in normal use.
$engine = if ($ux) { $ux.Exe } else { $null }
if ($engine) { Write-Ok "Engine located at: $engine" }

$progRule = Get-PCAirPlayProgramRuleName
if ($engine) {
    $existingProg = Get-NetFirewallRule -DisplayName $progRule -ErrorAction SilentlyContinue
    if ($existingProg) {
        # Repair rather than skip. A rule left pointing at a pre-upgrade path
        # permits nothing, and doctor.ps1 flags exactly that and tells the user
        # to re-run this script - which used to be a no-op, so the symptom never
        # cleared no matter how many times they ran it.
        $cur = ($existingProg | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        if ($cur -and $cur -ne $engine) {
            if ($PSCmdlet.ShouldProcess($progRule, "Repoint program filter to $engine")) {
                try {
                    $existingProg | Get-NetFirewallApplicationFilter |
                        Set-NetFirewallApplicationFilter -Program $engine -ErrorAction Stop
                    Write-Ok "Updated stale program path:"
                    Write-Note "  was: $cur"
                    Write-Note "  now: $engine"
                } catch {
                    Write-Bad "FAILED to repoint '$progRule': $($_.Exception.Message)"
                }
            }
        } else {
            Write-Ok "Rule already present and correct: $progRule"
        }
        Repair-RuleScope -Rule $existingProg -Name $progRule
    } elseif ($PSCmdlet.ShouldProcess($progRule, 'Create inbound allow rule')) {
        try {
            New-NetFirewallRule `
                -DisplayName $progRule `
                -Direction Inbound `
                -Action Allow `
                -Program $engine `
                -RemoteAddress $remote `
                -Profile Domain,Private,Public `
                -Description 'Allows the AirPlay receiver engine to accept connections on any port.' `
                -ErrorAction Stop | Out-Null
            Write-Ok "Created: $progRule"
        } catch {
            Write-Bad "FAILED to create '$progRule': $($_.Exception.Message)"
        }
    }
} else {
    Write-Warn "Engine exe not found - skipping the program-scoped rule."
}

# --- 5. Verify ------------------------------------------------------------
# Check what is actually on disk rather than trusting the steps above. An
# earlier version reported success while the rule it claimed to create did not
# exist.
if ($WhatIfPreference) {
    Write-Step "Verifying (skipped: -WhatIf preview, nothing was changed)"
} else {
    Write-Step "Verifying"

    $ux = Find-UxPlay      # re-resolve: the install happened after the first lookup
    if ($ux -and $ux.Kind -eq 'Cli') {
        Write-Ok "Engine: $($ux.Exe)$(if ($ux.Version) { " (version $($ux.Version))" })"
        if ($ux.PluginDir) {
            Write-Ok "GStreamer plugins: $($ux.PluginDir)"
            if (Test-Path (Join-Path $ux.PluginDir 'libgstd3d11.dll')) {
                Write-Ok "Hardware video sink (d3d11) present."
            } else {
                Write-Warn "d3d11 plugin missing - video will use a slower sink."
            }
        } else {
            Write-Bad "No gstreamer-1.0 plugin directory found near the engine."
            Write-Note "The receiver would start but show no video. Reinstall UxPlay."
            $script:failed++
        }
    } elseif ($ux -and $ux.Kind -eq 'GuiOnly') {
        Write-Bad "Installed build is 2.x (GUI only) - no uxplay.exe for the launchers."
        $script:failed++
    } else {
        Write-Bad "uxplay.exe still not found after install."
        $script:failed++
    }

    foreach ($n in (@($rules.Name) + @($progRule))) {
        # Get-FirewallRuleState, not a bare '-eq ''True''' on an unwrapped result:
        # .Enabled is an enum, and -DisplayName can return several rules, so the
        # naive test both reads as a string comparison and fails open. This is
        # the verify pass - it must not be the loosest check in the script.
        switch (Get-FirewallRuleState -Name $n) {
            'Enabled' { Write-Ok "Firewall rule active: $n" }
            'Disabled' {
                Write-Bad "Firewall rule exists but is DISABLED: $n"
                Write-Note "Enable-NetFirewallRule -DisplayName '$n'"
                $script:failed++
            }
            default {
                Write-Bad "Firewall rule missing: $n"
                $script:failed++
            }
        }
    }

    if ($script:InstallSource -eq 'winget') {
        Write-Warn "Installed via the winget fallback (1.72.1.3)."
        Write-Note "Same generation as the GitHub 1.x build, so nothing is lost - but"
        Write-Note "re-run without -UseWinget when GitHub is reachable to pick up 1.72.1-3."
    }
}

# --- Done -----------------------------------------------------------------
if ($WhatIfPreference) {
    Write-Step "Preview complete - nothing was changed"
    exit 0
}

if ($script:failed -gt 0) {
    Write-Step "Setup finished with $script:failed problem(s)"
    Write-Host "    Run .\doctor.ps1 for detail before relying on this." -ForegroundColor Yellow
    exit 1
}

Write-Step "Setup complete - everything verified"
Write-Host @"
    Next:
      1. Run  .\doctor.ps1        to verify network reachability
      2. Start the receiver:
           .\start-airplay.ps1     (command line)
           "AirPlayPC.cmd"        (desktop UI - just double-click it)
      3. On the iPhone: Control Center -> Screen Mirroring -> pick this PC

    Both devices must be on the SAME network/subnet. If the PC never appears,
    doctor.ps1 will tell you which of the usual causes applies.
"@ -ForegroundColor Gray
exit 0
