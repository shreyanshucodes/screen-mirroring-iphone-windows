[CmdletBinding()]
param(
    [string]$Name = "Presentation PC",
    [switch]$Pin
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $repoRoot 'Screen Mirroring for iPhone in Windows\Mirror-iPhone.ps1'

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Could not find the mirroring launcher at $launcher"
}

$arguments = @(
    '-Name', $Name,
    '-Fullscreen',
    '-ShareSafe'
)
if ($Pin) { $arguments += '-PIN' }

& $launcher @arguments
exit $LASTEXITCODE
