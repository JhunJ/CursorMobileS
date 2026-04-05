#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"

if [[ ! -f "$README" ]]; then
  echo "README not found: $README" >&2
  exit 1
fi

# README markdown image links: ![alt](path)
assets=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  assets+=("$line")
done < <(python3 - "$README" <<'PY'
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for m in re.finditer(r'!\[[^\]]*\]\(([^)]+)\)', readme):
    p = m.group(1).strip()
    if p.startswith("http://") or p.startswith("https://") or p.startswith("#"):
        continue
    print(p)
PY
)

missing=0
for rel in "${assets[@]}"; do
  path="$ROOT/$rel"
  if [[ ! -f "$path" ]]; then
    echo "Missing README asset: $rel" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "README assets OK (${#assets[@]} files)"
