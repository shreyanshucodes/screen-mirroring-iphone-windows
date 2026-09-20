[CmdletBinding()]
param(
    [string]$HostName = '127.0.0.1'
)

$ErrorActionPreference = 'SilentlyContinue'
$ports = 7000, 7001, 7100

Write-Host "iPhone Mirror network check" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor DarkGray

$bonjour = Get-Service -Name 'Bonjour Service'
if ($bonjour) {
    Write-Host ("Bonjour Service: {0}" -f $bonjour.Status) -ForegroundColor $(if ($bonjour.Status -eq 'Running') { 'Green' } else { 'Yellow' })
} else {
    Write-Host 'Bonjour Service: not installed' -ForegroundColor Red
}

foreach ($port in $ports) {
    $listener = Get-NetTCPConnection -LocalPort $port -State Listen
    if ($listener) {
        Write-Host "TCP ${port}: listening" -ForegroundColor Green
    } else {
        Write-Host "TCP ${port}: no listener (normal before UxPlay starts)" -ForegroundColor DarkGray
    }
}

$dns = Resolve-DnsName $HostName -ErrorAction SilentlyContinue
if ($dns) {
    Write-Host "DNS resolution for ${HostName}: OK" -ForegroundColor Green
} else {
    Write-Host "DNS resolution for ${HostName}: unavailable" -ForegroundColor Yellow
}
