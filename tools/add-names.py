#!/usr/bin/env python3
"""Add app names to shared/catalog.json, for example from an "App names" issue.

    python3 tools/add-names.py names.txt      (or paste the lines on stdin)

One app per line: "package = Name", or "package = English name | French name".
Other lines (the issue's text, code fences) are ignored. Packages the catalog already
names are skipped, never changed. Bumps the catalog version when something was added.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "shared/catalog.json"
LINE = re.compile(r"^\s*([A-Za-z][\w]*(?:\.[\w]+)+)\s*=\s*(.+?)\s*$")


def main() -> None:
    text = open(sys.argv[1], encoding="utf-8").read() if len(sys.argv) > 1 else sys.stdin.read()
    raw = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(raw)
    known = {p.get("id") for p in catalog["packages"]} | {n["id"] for n in catalog["names"]}

    added = []
    for line in text.splitlines():
        m = LINE.match(line)
        if not m or m.group(1) in known:
            continue
        en, _, fr = (s.strip() for s in m.group(2).partition("|"))
        if not en or len(en) > 60:
            continue
        known.add(m.group(1))
        added.append({"id": m.group(1), "name": {"en": en, "fr": fr or en}})

    if not added:
        print("Nothing new.")
        return
    # Insert as text before the end of "names", keeping the file's one-line-per-entry layout.
    start = raw.index('"names": [')
    end = raw.index("\n  ],", start)
    def entry(a: dict) -> str:
        name = json.dumps(a["name"], ensure_ascii=False)[1:-1]
        return f'    {{ "id": {json.dumps(a["id"])}, "name": {{ {name} }} }}'

    lines = ",\n".join(entry(a) for a in added)
    raw = raw[:end] + ",\n" + lines + raw[end:]
    raw = re.sub(r'"version": (\d+)', lambda v: f'"version": {int(v.group(1)) + 1}', raw, count=1)
    json.loads(raw)  # still valid
    CATALOG.write_text(raw, encoding="utf-8")
    print(f"Added {len(added)} name(s); catalog version {json.loads(raw)['version']}.")


if __name__ == "__main__":
    main()
