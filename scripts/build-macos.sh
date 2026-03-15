#!/usr/bin/env bash
# =============================================================================
# PearShare macOS build script
#
# Usage:
#   ./scripts/build-macos.sh                       # debug build
#   ./scripts/build-macos.sh --run                  # debug build + run locally
#   ./scripts/build-macos.sh --deploy               # debug build + rsync to laptop
#   ./scripts/build-macos.sh --run --deploy         # build + run locally + deploy to laptop
#   ./scripts/build-macos.sh --clean                # clean derived data first
#   ./scripts/build-macos.sh --release              # release build
#   ./scripts/build-macos.sh --release --archive    # build, sign, notarize
#
# Deploy target: dan@100.99.149.84 → ~/Downloads/PearShare.app
#
# Notarization setup (one-time):
#   xcrun notarytool store-credentials "pearshare-notarytool" \
#     --apple-id "dan@hexial.com" \
#     --team-id "5RH3UFJ9XD" \
#     --password "xxxx-xxxx-xxxx-xxxx"
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
DEPLOY_HOST="dan@100.99.149.84"

# ── Defaults ──────────────────────────────────────────────────────────────────
CONFIGURATION="Debug"
RUN=false
CLEAN=false
ARCHIVE=false
DEPLOY=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --release)  CONFIGURATION="Release" ;;
    --run)      RUN=true ;;
    --clean)    CLEAN=true ;;
    --archive)  ARCHIVE=true ;;
    --deploy)   DEPLOY=true ;;
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

  if command -v xcpretty &>/dev/null; then
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      CODE_SIGN_STYLE=Automatic \
      | xcpretty --color
  else
    xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      CODE_SIGN_STYLE=Automatic \
      -quiet
  fi

  echo "✓  Build complete"
}

# ── Archive → Sign → Notarize ─────────────────────────────────────────────────
do_archive() {
  echo "→  Archiving..."
  if command -v xcpretty &>/dev/null; then
    xcodebuild archive \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA" \
      -archivePath "$ARCHIVE_PATH" \
      -allowProvisioningUpdates \
      CODE_SIGN_STYLE=Automatic \
      | xcpretty --color
  else
    xcodebuild archive \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA" \
      -archivePath "$ARCHIVE_PATH" \
      -allowProvisioningUpdates \
      CODE_SIGN_STYLE=Automatic \
      -quiet
  fi

  echo "→  Exporting .app with Developer ID (Kubesail, Inc)..."
  cat > /tmp/pearshare-export-options.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>5RH3UFJ9XD</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist /tmp/pearshare-export-options.plist \
    -allowProvisioningUpdates

  echo "✓  Exported to $EXPORT_PATH/PearShare.app"

  do_notarize
}

# ── Notarize + staple ──────────────────────────────────────────────────────────
do_notarize() {
  local app_path="$EXPORT_PATH/PearShare.app"
  local zip_path="$REPO_ROOT/.build/PearShare-notarize.zip"

  echo "→  Zipping for notarization..."
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

  echo "→  Submitting to Apple notarization service (~2 min)..."
  xcrun notarytool submit "$zip_path" \
    --keychain-profile "pearshare-notarytool" \
    --wait \
    --timeout 10m

  echo "→  Stapling notarization ticket to .app..."
  xcrun stapler staple "$app_path"
  rm -f "$zip_path"

  echo "✓  Notarized and stapled: $app_path"
  echo "    This .app will run on any Mac without Gatekeeper prompts."
}

# ── Run locally ───────────────────────────────────────────────────────────────
do_run() {
  local app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION/PearShare.app"
  if [[ ! -d "$app_path" ]]; then
    echo "❌  Built app not found at $app_path"
    exit 1
  fi
  pkill -x PearShare 2>/dev/null && sleep 0.5 || true
  echo "→  Launching PearShare..."
  open "$app_path"
}

# ── Deploy (rsync over Tailscale SSH → laptop ~/Downloads) ────────────────────
do_deploy() {
  local app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION/PearShare.app"

  if [[ ! -d "$app_path" ]]; then
    echo "❌  Built app not found at $app_path"
    exit 1
  fi

  echo "→  Killing PearShare on $DEPLOY_HOST..."
  ssh "$DEPLOY_HOST" 'pkill -x PearShare 2>/dev/null && sleep 0.5 || true'

  echo "→  Syncing PearShare.app to $DEPLOY_HOST:~/Downloads/..."
  rsync -az --delete --progress \
    "$app_path" \
    "$DEPLOY_HOST:~/Downloads/"

  echo "✓  Deployed to $DEPLOY_HOST:~/Downloads/PearShare.app"
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
  if $DEPLOY; then
    echo ""
    do_deploy
  fi
fi

echo ""
echo "Done."
