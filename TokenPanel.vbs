' ============================================================
' TokenPanel.vbs - windowless launcher
'
' Double-click to start TokenPanel with no black console window.
'
' How it works: the 2nd argument of WScript.Shell.Run is the
' window mode; 0 = fully hidden. Launching powershell.exe that
' way means the console is hidden from the moment it is created,
' instead of being shown first and hidden afterwards.
'
' NOTE (encoding): keep this file pure ASCII. Windows Script Host
' reads .vbs as ANSI (the active code page). A UTF-8 file without
' BOM is mis-decoded on GBK/CP936 systems: the 3rd byte of a
' Chinese character is taken as a GBK lead byte and swallows the
' following ASCII quote, which produces
'   "Unterminated string constant" / 800A0409
' at compile time - the script never runs at all.
' If localized text is really needed, save this file as
' UTF-16 LE with BOM instead.
' ============================================================
Option Explicit

Dim sh, fso, baseDir, scriptPath, cmdLine

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "TokenPanel.ps1")

If Not fso.FileExists(scriptPath) Then
    MsgBox "TokenPanel.ps1 was not found." & vbCrLf & vbCrLf & _
           "TokenPanel.vbs must sit in the same folder as the program files." & vbCrLf & _
           "Current folder: " & baseDir, 16, "TokenPanel"
    WScript.Quit 1
End If

cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

' Window mode 0 = hidden; False = do not wait, return immediately
sh.Run cmdLine, 0, False
