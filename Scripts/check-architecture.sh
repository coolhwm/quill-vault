#!/bin/sh

set -eu

if ! command -v rg >/dev/null 2>&1; then
    echo "Architecture checks require ripgrep (rg)." >&2
    exit 127
fi

failure=0

ruby Scripts/validate-package-graph-test.rb

report_matches() {
    description="$1"
    pattern="$2"
    shift 2

    matches="$(rg -n "$pattern" "$@" 2>/dev/null || true)"
    if [ -n "$matches" ]; then
        echo "$description"
        echo "$matches"
        failure=1
    fi
}

report_matches \
    "The MVP must not reference QuillvaultDemo." \
    "QuillvaultDemo" \
    Quillvault.xcodeproj QuillvaultApp Packages

report_matches \
    "Feature modules must not import sibling feature modules." \
    "^import [A-Za-z][A-Za-z0-9_]*Feature$" \
    --glob "**/Sources/*Feature/**/*.swift" \
    Packages

report_matches \
    "Feature modules must not import concrete infrastructure frameworks." \
    "^import (GRDB|AVFoundation|AVFAudio|Speech|WebKit|Security)$" \
    --glob "**/Sources/*Feature/**/*.swift" \
    Packages

report_matches \
    "Domain must not import UI or infrastructure frameworks." \
    "^import (SwiftUI|GRDB|AVFoundation|AVFAudio|Speech|WebKit|Security)$" \
    --glob "**/Sources/Domain/**/*.swift" \
    Packages

report_matches \
    "Application must not import UI or concrete infrastructure frameworks." \
    "^import (SwiftUI|GRDB|AVFoundation|AVFAudio|Speech|WebKit|Security)$" \
    --glob "**/Sources/Application/**/*.swift" \
    Packages

report_matches \
    "Infrastructure must not import presentation or application modules." \
    "^import (AppNavigation|Application|DesignSystem|[A-Za-z][A-Za-z0-9_]*Feature)$" \
    --glob "**/*Infrastructure/Sources/**/*.swift" \
    Packages

for package_manifest in Packages/*/Package.swift; do
    package_directory="$(dirname "$package_manifest")"
    if ! swift package --package-path "$package_directory" dump-package \
        | ruby Scripts/validate-package-graph.rb; then
        failure=1
    fi
done

banned_paths="$(rg --files Packages QuillvaultApp | rg '/(Manager|Helper|Utils|Common)(/|\\.)' || true)"
if [ -n "$banned_paths" ]; then
    echo "Focused modules must not introduce generic responsibility buckets."
    echo "$banned_paths"
    failure=1
fi

exit "$failure"
