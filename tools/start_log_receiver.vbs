' CameraApp log receiver - windowless background launcher.
' Called by the scheduled task "CameraApp Log Receiver" at user logon.
' Starts pythonw.exe via WScript.Shell.Run with window style 0 (hidden),
' so no console window flashes.
' ASCII only on purpose (Windows Script Host reads .vbs as ANSI).
Option Explicit

Dim fso, shell, scriptDir, target, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
target = fso.BuildPath(scriptDir, "log_receiver.py")

If Not fso.FileExists(target) Then
    WScript.Quit 2
End If

cmd = "pythonw.exe """ & target & """"
' 0 = hidden window, False = do not wait (the server runs forever)
shell.Run cmd, 0, False
