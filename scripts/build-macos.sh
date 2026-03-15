#!/usr/bin/env bash
# =============================================================================
# PearShare macOS build script
#
# Usage:
#   ./scripts/build-macos.sh                  # debug build, runs the app
#   ./scripts/build-macos.sh --release         # release build (no auto-run)
#   ./scripts/build-macos.sh --run             # debug build + run
#   ./scripts/build-macos.sh --clean           # clean derived data first
#   ./scripts/build-macos.sh --release --archive  # build a distributable .app
#
# First-time setup:
#   1. Install Xcode from the App Store
#   2. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#   3. Run: xcodebuild -project clients/macos/PearShare.xcodeproj \
#              -scheme PearShare -allowProvisioningUpdates
#      (opens browser to approve provisioning — one time only)
#   4. After that, this script works headlessly forever.
# =============================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/clients/macos/PearShare.xcodeproj"
SCHEME="PearShare"
DERIVED_DATA="$REPO_ROOT/.build/macos-derived-data"
ARCHIVE_PATH="$REPO_ROOT/.build/PearShare.xcarchive"
EXPORT_PATH="$REPO_ROOT/.build/PearShare-export"

# ── Defaults ──────────────────────────────────────────────────────────────────
CONFIGURATION="Debug"
RUN=false
CLEAN=false
ARCHIVE=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --release)  CONFIGURATION="Release" ;;
    --run)      RUN=true ;;
    --clean)    CLEAN=true ;;
    --archive)  ARCHIVE=true ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ── Prereq checks ─────────────────────────────────────────────────────────────
check_xcode() {
  if ! command -v xcodebuild &>/dev/null; then
    echo "❌  xcodebuild not found. Install Xcode from the App Store."
    exit 1
  fi
  local dev_dir
  dev_dir="$(xcode-select -p 2>/dev/null)"
  if [[ "$dev_dir" == *"CommandLineTools"* ]]; then
    echo "❌  Active developer directory is Command Line Tools, not Xcode."
    echo "    Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
  fi
  echo "✓  Xcode: $(xcodebuild -version | head -1) @ $dev_dir"
}

check_tailscale() {
  if ! command -v tailscale &>/dev/null; then
    echo "⚠   Tailscale CLI not found — peer discovery won't work at runtime."
    echo "    Install from https://tailscale.com/download"
  else
    echo "✓  Tailscale: $(tailscale version | head -1)"
  fi
}

# ── Clean ─────────────────────────────────────────────────────────────────────
do_clean() {
  echo "→  Cleaning derived data..."
  rm -rf "$DERIVED_DATA"
  xcodebuild clean \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -quiet
  echo "✓  Clean complete"
}

# ── Build ─────────────────────────────────────────────────────────────────────
do_build() {
  echo "→  Building PearShare ($CONFIGURATION)..."
  mkdir -p "$DERIVED_DATA"

  # -allowProvisioningUpdates lets xcodebuild refresh certs non-interactively
  # after the first time you've approved them in the GUI.
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    | xcpretty --color 2>/dev/null || cat  # fall back to raw output if xcpretty not installed

  echo "✓  Build complete"
}

# ── Archive (distributable .app) ──────────────────────────────────────────────
do_archive() {
  echo "→  Archiving..."
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    | xcpretty --color 2>/dev/null || cat

  echo "→  Exporting .app..."
  # Export as a Developer ID signed app (not App Store)
  cat > /tmp/pearshare-export-options.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$(DEVELOPMENT_TEAM)</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist /tmp/pearshare-export-options.plist \
    -allowProvisioningUpdates

  echo "✓  Exported to $EXPORT_PATH/PearShare.app"
}

# ── Run ───────────────────────────────────────────────────────────────────────
do_run() {
  local app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION/PearShare.app"
  if [[ ! -d "$app_path" ]]; then
    echo "❌  Built app not found at $app_path"
    exit 1
  fi
  echo "→  Launching PearShare..."
  open "$app_path"
}

# ── App path helper ───────────────────────────────────────────────────────────
print_app_path() {
  local app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION/PearShare.app"
  if [[ -d "$app_path" ]]; then
    echo ""
    echo "    App: $app_path"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo "PearShare build"
echo "────────────────"
check_xcode
check_tailscale
echo ""

if $CLEAN; then
  do_clean
  echo ""
fi

if $ARCHIVE; then
  CONFIGURATION="Release"
  do_archive
else
  do_build
  print_app_path
  if $RUN; then
    echo ""
    do_run
  fi
fi

echo ""
echo "Done."
