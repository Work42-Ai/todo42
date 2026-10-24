#!/usr/bin/env bash
# sync-shared.sh — copy the plugin's shared Swift files into the widgets that use them.
#
# Every widget compiles as its own dylib from its own Sources/ folder, so code shared by several widgets lives
# once in work42-plugin/shared/ and is copied next to each widget's Widget.swift. The copies are committed;
# `scripts/sync-shared.sh --check` fails when one has drifted (run it before committing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)/work42-plugin"
# "<shared file>:<widget> <widget> …"
MAP=(
  "Todo42Model.swift:todos my-planned-day"
)

status=0
for entry in "${MAP[@]}"; do
  file="${entry%%:*}"; widgets="${entry#*:}"
  for widget in $widgets; do
    dest="$ROOT/widgets/$widget/Sources/$file"
    if [[ "${1:-}" == "--check" ]]; then
      cmp -s "$ROOT/shared/$file" "$dest" || { echo "out of sync: widgets/$widget/Sources/$file (run scripts/sync-shared.sh)" >&2; status=1; }
    else
      cp "$ROOT/shared/$file" "$dest"
      echo "synced widgets/$widget/Sources/$file"
    fi
  done
done
exit $status
