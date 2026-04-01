#!/usr/bin/env bash
# =============================================================================
# PearShare macOS build script
#
# Usage:
#   ./scripts/build-macos.sh                       # build, then auto-run/deploy per .env
#   ./scripts/build-macos.sh --clean                # clean derived data first
#   ./scripts/build-macos.sh --release              # release build
#   ./scripts/build-macos.sh --release --archive    # build, sign, notarize
#
# Post-build actions are driven by DEPLOY_HOSTS in .env (no flags needed):
#   DEPLOY_HOSTS="local"                    → build + launch on this machine
#   DEPLOY_HOSTS="user@host1"               → build + rsync + launch on host1
#   DEPLOY_HOSTS="local user@host1"         → build + launch locally + deploy to host1
#   DEPLOY_HOSTS=""  (or unset)             → build only
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

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -o allexport; source "$ENV_FILE"; set +o allexport
fi

# DEPLOY_HOSTS: space-separated list of user@host targets (from .env)
DEPLOY_HOSTS="${DEPLOY_HOSTS:-}"

# ── Defaults ──────────────────────────────────────────────────────────────────
CONFIGURATION="Debug"
CLEAN=false
ARCHIVE=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --release)  CONFIGURATION="Release" ;;
    --clean)    CLEAN=true ;;
    --archive)  ARCHIVE=true ;;
    --help|-h)
      sed -n '2,22p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ── Derive run/deploy targets from DEPLOY_HOSTS ───────────────────────────────
RUN_LOCAL=false
REMOTE_HOSTS=()
for target in $DEPLOY_HOSTS; do
  if [[ "$target" == "local" ]]; then
    RUN_LOCAL=true
  else
    REMOTE_HOSTS+=("$target")
  fi
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
  "$REPO_ROOT/scripts/generate-build-info.sh"
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

# ── Deploy (rsync over Tailscale SSH) ────────────────────────────────────────
deploy_to_host() {
  local host="$1"
  local app_path="$2"

  echo "→  [$host] Stopping PearShare..."
  ssh "$host" 'pkill -x PearShare 2>/dev/null && sleep 0.5 || true'

  # Always deploy to /Applications on the remote host.
  # ~/Downloads triggers macOS Gatekeeper translocation: the first `open` runs the app from a
  # randomized /private/var/folders/ path, so future deploys to ~/Downloads are ignored.
  # /Applications is never translocated and is writable by admin users without sudo.
  local remote_parent="/Applications"

  echo "→  [$host] Syncing PearShare.app to $remote_parent/..."
  rsync -az --delete --progress \
    "$app_path" \
    "$host:$remote_parent/"

  echo "→  [$host] Launching PearShare..."
  ssh "$host" "xattr -rd com.apple.quarantine \"$remote_parent/PearShare.app\" 2>/dev/null || true; open \"$remote_parent/PearShare.app\""

  echo "✓  [$host] Deployed and launched"
}

do_deploy() {
  local app_path="$DERIVED_DATA/Build/Products/$CONFIGURATION/PearShare.app"

  if [[ ! -d "$app_path" ]]; then
    echo "❌  Built app not found at $app_path"
    exit 1
  fi

  local pids=()
  local deployed_hosts=()

  # Fan out to all remote hosts in parallel
  for host in "${REMOTE_HOSTS[@]}"; do
    deploy_to_host "$host" "$app_path" &
    pids+=($!)
    deployed_hosts+=("$host")
  done

  # Wait for all and collect failures
  local failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      echo "❌  Deploy failed for ${deployed_hosts[$i]}"
      failed=1
    fi
  done

  [[ $failed -eq 0 ]] || exit 1
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
  if $RUN_LOCAL; then
    echo ""
    do_run
  fi
  if [[ ${#REMOTE_HOSTS[@]} -gt 0 ]]; then
    echo ""
    do_deploy
  fi
fi

echo ""
echo "Done."
