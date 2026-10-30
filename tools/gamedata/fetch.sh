#!/usr/bin/env bash
# Downloads the DB2 CSV exports listed in tables.txt from wago.tools for one client build.
# Usage: bash tools/gamedata/fetch.sh <version.build>     e.g. bash tools/gamedata/fetch.sh 12.1.5.70575
# Writes tools/gamedata/cache/<version.build>/<Table>.csv and skips tables already downloaded.
# UNVERIFIED: the URL pattern and the array-column header style (Pos[0] or Pos_0) have not been
# checked against wago.tools yet; see tools/gamedata/README.md.
set -euo pipefail

build="${1:-}"
if [[ ! "$build" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: fetch.sh <version.build>  (e.g. 12.1.5.70575)" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/cache/$build"
mkdir -p "$dest"

while IFS= read -r line || [[ -n "$line" ]]; do
  table="${line%%#*}"
  table="${table//[[:space:]]/}"
  [[ -z "$table" ]] && continue
  out="$dest/$table.csv"
  if [[ -e "$out" ]]; then
    echo "skip  $table (cached)"
    continue
  fi
  echo "fetch $table"
  curl -fsSL "https://wago.tools/db2/$table/csv?build=$build" -o "$out.part"
  mv "$out.part" "$out"
done < "$here/tables.txt"
