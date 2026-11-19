#!/usr/bin/env bash
# Optional: copies a typeface of your choice into the app bundle sources. Spur registers the
# first font file it finds in Spur/Resources/Fonts/ at launch and otherwise uses the system font.
# Font files are kept out of git: only use a font you are licensed to embed in an app.
#
#   scripts/install-font.sh /path/to/Font.ttf
#
# Without an argument the path is read from Config/Local.font (one line, gitignored).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-}"
if [[ -z "$src" && -f "$root/Config/Local.font" ]]; then src="$(head -n 1 "$root/Config/Local.font")"; fi
if [[ -z "$src" || ! -f "$src" ]]; then
  echo "no font file given; the app uses the system font" >&2
  exit 0
fi
mkdir -p "$root/Spur/Resources/Fonts"
cp "$src" "$root/Spur/Resources/Fonts/$(basename "$src")"
echo "ok: font copied"
