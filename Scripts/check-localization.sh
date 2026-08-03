#!/usr/bin/env bash
# Soft guard: flag likely hardcoded user-facing Chinese/English string literals
# in Feature Views. Exits non-zero only when -strict is passed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
strict=0
if [[ "${1:-}" == "-strict" ]]; then
  strict=1
fi

matches="$(
  rg -n --glob '*.swift' \
    -e 'Text\(\s*"[^"]{4,}"\s*\)' \
    -e 'Label\(\s*"[^"]{4,}"' \
    -e 'navigationTitle\(\s*"[^"]+"' \
    "$root/Packages/QuillvaultFeatures/Sources" \
    "$root/QuillvaultApp" \
    2>/dev/null \
    | rg -v 'accessibilityIdentifier|systemImage|Text\(verbatim|LocalizedStringKey|#"|"tab\.|"settings\.|"home\.|"minutes\.|"recording\.|"profile\.|"brand\.|"common\.' \
    || true
)"

if [[ -n "$matches" ]]; then
  echo "Possible hardcoded UI strings:"
  echo "$matches"
  if [[ "$strict" -eq 1 ]]; then
    exit 1
  fi
else
  echo "No high-confidence hardcoded Feature UI string literals found."
fi
