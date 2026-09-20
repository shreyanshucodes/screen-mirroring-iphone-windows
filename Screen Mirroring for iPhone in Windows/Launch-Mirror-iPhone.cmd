@echo off
:: Launch-Mirror-iPhone.cmd
:: Double-click launcher for Screen Mirroring for iPhone in Windows
:: Provides zero-console-flash launch similar to the original AirPlayPC.cmd

:: Set up environment for PowerShell script execution
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Mirror-iPhone.ps1"

:: Check if the PowerShell script exists
if not exist "%PS_SCRIPT%" (
    echo.
    echo ERROR: Could not find Mirror-iPhone.ps1
    echo Make sure this file is in the Screen Mirroring for iPhone in Windows folder
    echo.
    pause
    exit /b 1
)

:: Launch PowerShell script with hidden console (no flash)
:: Using powershell.exe directly with -WindowStyle Hidden and -NoProfile
:: We wrap in a try/catch to handle errors gracefully
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "
try {
    Add-Type -AssemblyName PresentationFramework
    & '%PS_SCRIPT%' %*
    if ($LASTEXITCODE) {
        throw ('Mirror-iPhone.ps1 exited with code ' + $LASTEXITCODE + '.')
    }
} catch {
    $errorMsg = 'Screen Mirroring failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message
    try {
        Set-Content -LiteralPath ('%TEMP%\ScreenMirroringError.log') -Value ($errorMsg + [Environment]::NewLine + $_.ScriptStackTrace)
    } catch {}
    try {
        [void][System.Windows.MessageBox]::Show($errorMsg, 'Screen Mirroring for iPhone', 'OK', 'Error')
    } catch {}
    exit 1
}
"
exit /b %errorlevel%