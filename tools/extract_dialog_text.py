#!/usr/bin/env python3
"""Extracts the real Hebrew dialogue-choice text from WDL/DIalog.wdl.

DIalog.wdl's own `ShowDialog()`/`SetDialogOptions()` machinery assigns
`txt1.string`/`txt2.string`/`txt3.string` per `DialogIndex` to a REVERSED,
per-letter-substituted (a->cipher) placeholder string -- Acknex's own text
engine displayed those directly, presumably via a runtime font/codec this
port has no equivalent for. But every one of those assignment lines ALSO
carries the real, already-decoded Hebrew text as a trailing `//` comment
(added by the original developer, not this port), e.g.:

    txt1.string = "...JMP S'RE VA JL XUFT EVA JVML GA";// [hebrew text]

This script pulls those comments out directly, generically, for EVERY
`DialogIndex` block in the file (57 as of this writing, only 5 of which
were ever hand-transcribed into a hardcoded GDScript table before) --
supersedes that hardcoded table entirely, see GameHud._dialog_lines().

Usage: python tools/extract_dialog_text.py
Output: assets/converted/dialog_text.json -- {"<index>": [line1, line2, line3]}
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "original" / "piposh3d" / "WDL" / "DIalog.wdl"
OUT = Path(__file__).resolve().parent.parent / "assets" / "converted" / "dialog_text.json"

# One `if (DialogIndex == N) { txt1.string = "...";// TEXT ... }` block.
BLOCK_RE = re.compile(
    r"if\s*\(\s*DialogIndex\s*==\s*(\d+)\s*\)\s*\{(.*?)\}",
    re.DOTALL,
)
# `txtN.string = "...";// TEXT` -- capture everything after `//` to end of line.
TXT_RE = re.compile(r'txt(\d)\.string\s*=\s*"[^"]*"\s*;\s*//\s*(.*)')


def main() -> int:
    if not SOURCE.exists():
        print(f"ERROR: {SOURCE} not found", file=sys.stderr)
        return 1
    text = SOURCE.read_bytes().decode("windows-1255")

    result: dict[str, list[str]] = {}
    for m in BLOCK_RE.finditer(text):
        index = m.group(1)
        body = m.group(2)
        lines: dict[int, str] = {}
        for line in body.splitlines():
            tm = TXT_RE.search(line)
            if tm:
                lines[int(tm.group(1))] = tm.group(2).strip()
        if not lines:
            continue
        ordered = [lines.get(1, ""), lines.get(2, ""), lines.get(3, "")]
        # Drop trailing empty slots (some blocks only ever use 1-2 lines),
        # but keep interior gaps as empty strings.
        while ordered and ordered[-1] == "":
            ordered.pop()
        result[index] = ordered

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    print(f"Wrote {len(result)} DialogIndex entries to {OUT}")
    missing = [i for i in range(max(int(k) for k in result) + 1) if str(i) not in result]
    if missing:
        print(f"NOTE: no block found for DialogIndex {missing} (gaps in the source file itself)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
