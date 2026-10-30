' ============================================================
'  TokenPocket.vbs — 无窗口启动器
'
'  双击本文件即可启动 Token Pocket，不会出现黑色控制台窗口。
'
'  原理：WScript.Shell.Run 的第二个参数是「窗口模式」，
'        0 = 完全隐藏。用它拉起 powershell.exe，
'        控制台从创建起就是隐藏的，不会「先显示再隐藏」。
'
'  对比旧写法（start "" powershell.exe -WindowStyle Hidden）：
'        start 会先给 powershell 开一个新控制台（可见），
'        PowerShell 启动后才执行 -WindowStyle Hidden 把它藏起来，
'        中间那一下就是用户看到的黑窗闪。
' ============================================================
Option Explicit

Dim sh, fso, baseDir, scriptPath, cmdLine

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "TokenPanel.ps1")

If Not fso.FileExists(scriptPath) Then
    MsgBox "找不到 TokenPanel.ps1。" & vbCrLf & vbCrLf & _
           "请确认 TokenPocket.vbs 与程序文件在同一个文件夹里。" & vbCrLf & _
           "当前目录：" & baseDir, 16, "Token Pocket"
    WScript.Quit 1
End If

cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

' 参数 0 = 隐藏窗口；False = 不等待，立即返回
sh.Run cmdLine, 0, False
