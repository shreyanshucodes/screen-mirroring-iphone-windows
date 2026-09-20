' Launch-Mirror-iPhone.vbs
' Zero-flash double-click launcher for Screen Mirroring for iPhone in Windows
' Creates a hidden PowerShell console to launch our mirroring script

Option Explicit
Dim sh, fso, env, cmd, scriptPath, scriptDir

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptDir = Replace(scriptDir, "/", "\") ' Normalize path separators
If Right(scriptDir, 1) <> "\" Then scriptDir = scriptDir & "\"

' Build path to our PowerShell script
scriptPath = scriptDir & "Mirror-iPhone.ps1"

' Check if script exists
If Not fso.FileExists(scriptPath) Then
    MsgBox "ERROR: Could not find Mirror-iPhone.ps1" & vbCrLf & _
           "Make sure this file is in the Screen Mirroring for iPhone in Windows folder.", _
           vbCritical, "Screen Mirroring for iPhone"
    WScript.Quit 1
End If

' Build the PowerShell command line
env = sh.Environment("PROCESS")
env("SCRIPT_PATH") = Chr(34) & scriptPath & Chr(34) ' Quote the path

cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & _
      Chr(34) & "$ErrorActionPreference = 'Stop'; Try { Add-Type -AssemblyName PresentationFramework; & $env:SCRIPT_PATH; if ($LASTEXITCODE) { throw ('Mirror-iPhone.ps1 exited with code ' + $LASTEXITCODE + '.') } } Catch { $m = 'Screen Mirroring failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message; Try { Set-Content -LiteralPath ($env:TEMP + '\ScreenMirroringError.log') -Value ($m + [Environment]::NewLine + $_.ScriptStackTrace) } Catch {}; Try { [void][System.Windows.MessageBox]::Show($m, 'Screen Mirroring for iPhone', 'OK', 'Error') } Catch {}; exit 1 }" & Chr(34)

' Launch with window style 0 (hidden) - no console flash whatsoever
sh.Run cmd, 0, False