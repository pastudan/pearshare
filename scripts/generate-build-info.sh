#!/usr/bin/env bash
# Generates BuildInfo.generated.swift with git metadata.
# Can be invoked two ways:
#   1. From build-macos.sh (SRCROOT not set — uses paths relative to this script)
#   2. From an Xcode Run Script build phase (SRCROOT is set by Xcode)

set -euo pipefail

if [ -n "${SRCROOT:-}" ]; then
    REPO_ROOT="$(cd "$SRCROOT/../.." && pwd)"
    OUT="$SRCROOT/PearShare/BuildInfo.generated.swift"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    OUT="$REPO_ROOT/clients/macos/PearShare/BuildInfo.generated.swift"
fi

COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Check for tracked-file changes (excludes untracked ??-prefixed lines)
if git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -qE "^[^?]"; then
    DIRTY=true
else
    DIRTY=false
fi

# Truncate to 60 chars and escape any double quotes
MESSAGE=$(git -C "$REPO_ROOT" log -1 --format="%s" 2>/dev/null | cut -c1-60 || echo "")
MESSAGE="${MESSAGE//\"/\'}"

cat > "$OUT" <<SWIFT
// AUTO-GENERATED — do not edit. Regenerated at build time by generate-build-info.sh.
enum BuildInfo {
    static let gitCommit  = "$COMMIT"
    static let gitDirty   = $DIRTY
    static let gitMessage = "$MESSAGE"
}
SWIFT
