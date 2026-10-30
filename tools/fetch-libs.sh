#!/usr/bin/env bash
# Populates Libs/ for local development (Libs/ is git-ignored; the BigWigs packager
# resolves the real externals from .pkgmeta on GitHub releases).
#
# Needs only bash and curl. Libraries are fetched file-by-file from
# raw.githubusercontent.com (repos.wowace.com is not required), following the
# <Script>/<Include> entries of each library's .xml so the file set matches upstream.
#
# For local play, symlink the repo into
#   World of Warcraft/_retail_/Interface/AddOns/FabricationStation
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="$ROOT/Libs"
ACE3="https://raw.githubusercontent.com/WoWUIDev/Ace3/master"
LDB="https://raw.githubusercontent.com/tekkub/libdatabroker-1-1/master"
# LibDBIcon has no official GitHub home; try mirrors in order (newest first).
DBICON_MIRRORS=(
  "https://raw.githubusercontent.com/kaldown/LibDBIcon-1.0/main/LibDBIcon-1.0.lua"
  "https://raw.githubusercontent.com/wowace-clone/LibDBIcon-1.0/main/LibDBIcon-1.0/LibDBIcon-1.0.lua"
  "https://raw.githubusercontent.com/WoWAddonMirrors/LibDBIcon-1.0/main/LibDBIcon-1.0/LibDBIcon-1.0.lua"
)

UNAVAILABLE=()

fetch() { # fetch <url> <dest>
  mkdir -p "$(dirname "$2")"
  curl -fsSL --retry 2 -o "$2" "$1"
}

# fetch_xml <base-url> <lib-dir> <xml-relative-path>: fetch an XML manifest and every file it references.
fetch_xml() {
  local base="$1" lib="$2" xml="$3" ref dir
  fetch "$base/$lib/$xml" "$LIBS/$lib/$xml"
  dir="$(dirname "$xml")"
  [ "$dir" = "." ] && dir=""
  while IFS= read -r ref; do
    ref="${ref//\\//}"
    [ -n "$dir" ] && ref="$dir/$ref"
    case "$ref" in
      *.xml) fetch_xml "$base" "$lib" "$ref" ;;
      *) fetch "$base/$lib/$ref" "$LIBS/$lib/$ref" ;;
    esac
  done < <(sed -E 's/<!--.*-->//g' "$LIBS/$lib/$xml" | grep -oE '(Script|Include) file="[^"]+"' | sed -E 's/.*file="([^"]+)"/\1/')
}

rm -rf "$LIBS"
mkdir -p "$LIBS"

fetch "$ACE3/LibStub/LibStub.lua" "$LIBS/LibStub/LibStub.lua"
for lib in CallbackHandler-1.0 AceAddon-3.0 AceEvent-3.0 AceConsole-3.0 AceDB-3.0 AceGUI-3.0 AceConfig-3.0; do
  fetch_xml "$ACE3" "$lib" "$lib.xml"
done
fetch "$LDB/LibDataBroker-1.1.lua" "$LIBS/LibDataBroker-1.1/LibDataBroker-1.1.lua"

ok=0
for url in "${DBICON_MIRRORS[@]}"; do
  if fetch "$url" "$LIBS/LibDBIcon-1.0/LibDBIcon-1.0.lua" 2>/dev/null; then ok=1; break; fi
done
if [ "$ok" -eq 0 ]; then
  rm -rf "$LIBS/LibDBIcon-1.0"
  UNAVAILABLE+=("LibDBIcon-1.0")
fi

if [ "${#UNAVAILABLE[@]}" -gt 0 ]; then
  echo "WARNING: unavailable libraries: ${UNAVAILABLE[*]}" >&2
fi
echo "Libs populated in $LIBS:"
ls "$LIBS"
