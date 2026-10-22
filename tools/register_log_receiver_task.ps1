# Register / manage the "CameraApp Log Receiver" auto-start scheduled task.
#
# Usage (run from the camera_app directory):
#   powershell -ExecutionPolicy Bypass -File tools\register_log_receiver_task.ps1
#   powershell -ExecutionPolicy Bypass -File tools\register_log_receiver_task.ps1 -Unregister
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI and would
# mangle non-ASCII characters.

param(
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$TaskName = 'CameraApp Log Receiver'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $ScriptDir 'start_log_receiver.vbs'

if ($Unregister) {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" |
        Where-Object { $_.CommandLine -like '*log_receiver.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Write-Host 'Removed scheduled task and stopped the log receiver.'
    return
}

if (-not (Test-Path $Launcher)) { throw "Launcher not found: $Launcher" }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $Launcher + '"')

# Start at logon (no admin rights needed); the socket is ready as soon as the
# network is up, so the phone can upload right away.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) `
    -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description 'Receives camera app logs on 0.0.0.0:8080 -> tools/logs_received/' | Out-Null

Write-Host "Registered scheduled task: $TaskName"
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
