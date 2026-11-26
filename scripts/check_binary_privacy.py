#!/usr/bin/env python3
"""Reject private build paths in all bytes, including Mach-O symbol tables."""
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
for marker in (b"/Users/", b"/home/", b"codex-clipboard-"):
    if marker in data:
        print("FAIL: private path marker in executable; no matched value printed")
        sys.exit(1)
print("Executable privacy markers: 0")
