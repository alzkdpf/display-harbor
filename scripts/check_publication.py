#!/usr/bin/env python3
"""Check tracked publication files without printing potentially sensitive values."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
patterns = {
    "credential-like token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "personal filesystem path": re.compile(rb"(?:/Users/|/home/)[A-Za-z0-9_.-]+/"),
    "clipboard attachment": re.compile(rb"codex-clipboard-[0-9a-f-]+"),
}
email = re.compile(rb"[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
forbidden_suffixes = {".zip", ".dmg", ".log", ".ips", ".p12", ".pfx", ".pem", ".key", ".png", ".jpg", ".jpeg", ".mp4", ".mov"}
issues = []
count = 0
for raw in files:
    if not raw:
        continue
    relative = raw.decode("utf-8")
    path = root / relative
    count += 1
    if path.is_symlink():
        issues.append((relative, "symbolic link"))
        continue
    if path.suffix.lower() in forbidden_suffixes or path.name.startswith(".env"):
        issues.append((relative, "non-source or private file type"))
    data = path.read_bytes()
    for label, pattern in patterns.items():
        if pattern.search(data):
            issues.append((relative, label))
    # Public upstream attribution notices are required, not user contact data.
    if not relative.startswith("third_party/"):
        for match in email.findall(data):
            if not match.endswith(b"@users.noreply.github.com"):
                issues.append((relative, "unexpected contact address"))
                break
for path, label in issues:
    print(f"FAIL {path}: {label}")
print(f"Checked {count} tracked files; findings: {len(issues)}")
sys.exit(bool(issues))
