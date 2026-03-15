#!/usr/bin/env bash
# =============================================================================
# PearShare first-time developer setup script
#
# Run this once after cloning the repo. It:
#   1. Verifies/installs Xcode
#   2. Sets Xcode as the active developer directory
#   3. Accepts the Xcode license
#   4. Opens the project so you can set your signing Team (one GUI step)
#   5. Triggers a first provisioning run
#   6. Optionally installs xcpretty (nicer build output)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/clients/macos/PearShare.xcodeproj"

echo ""
echo "PearShare — first-time setup"
echo "══════════════════════════════"
echo ""

# ── Step 1: Check Xcode ───────────────────────────────────────────────────────
echo "Step 1/5: Checking Xcode..."

if [[ ! -d "/Applications/Xcode.app" ]]; then
  echo ""
  echo "  Xcode is not installed."
  echo "  Opening App Store to the Xcode page..."
  open "https://apps.apple.com/app/xcode/id497799835"
  echo ""
  echo "  Install Xcode, then re-run this script."
  exit 1
fi

XCODE_VER=$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "unknown")
echo "  ✓ Xcode $XCODE_VER found"

# ── Step 2: Set active developer directory ────────────────────────────────────
echo ""
echo "Step 2/5: Setting Xcode as active developer toolchain..."

CURRENT_DEV=$(xcode-select -p 2>/dev/null || echo "")
if [[ "$CURRENT_DEV" == *"CommandLineTools"* ]] || [[ -z "$CURRENT_DEV" ]]; then
  echo "  Switching from Command Line Tools to Xcode (requires sudo)..."
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  echo "  ✓ Done"
else
  echo "  ✓ Already set to Xcode ($CURRENT_DEV)"
fi

# ── Step 3: Accept Xcode license ──────────────────────────────────────────────
echo ""
echo "Step 3/5: Accepting Xcode license..."
if ! xcodebuild -license check &>/dev/null; then
  echo "  Accepting license (requires sudo)..."
  sudo xcodebuild -license accept
  echo "  ✓ License accepted"
else
  echo "  ✓ License already accepted"
fi

# ── Step 4: Signing Team (GUI step) ───────────────────────────────────────────
echo ""
echo "Step 4/5: Signing team setup (one-time GUI step)"
echo ""
echo "  This is the one step that requires the Xcode GUI."
echo ""
echo "  PearShare.xcodeproj is opening now. Please:"
echo "    1. Click 'PearShare' in the project navigator (top-left)"
echo "    2. Select the 'PearShare' target"  
echo "    3. Go to 'Signing & Capabilities' tab"
echo "    4. Under 'Team', select your Apple ID"
echo "       (Add one via Xcode → Settings → Accounts if needed)"
echo "    5. Wait for Xcode to say 'Provisioning Profile: Xcode Managed Profile'"
echo "    6. Close Xcode"
echo ""
read -p "  Press Enter to open Xcode (or Ctrl+C to skip)..."
open "$PROJECT"
echo ""
read -p "  Press Enter once you've set your Team and closed Xcode..."

# ── Step 5: First provisioning run ────────────────────────────────────────────
echo ""
echo "Step 5/5: First provisioning run (downloads certs automatically)..."
echo ""

# Detect the team ID that was just written into the project
TEAM_ID=$(grep -A2 "DEVELOPMENT_TEAM" "$PROJECT/project.pbxproj" 2>/dev/null \
  | grep -o '[A-Z0-9]\{10\}' | head -1 || echo "")

if [[ -z "$TEAM_ID" ]]; then
  echo "  ⚠  Could not detect Team ID from project — skipping provisioning preflight."
  echo "     Run './scripts/build-macos.sh' and it will provision on first build."
else
  echo "  Team ID detected: $TEAM_ID"
  echo "  Triggering provisioning (may open browser once to approve)..."
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "PearShare" \
    -configuration Debug \
    -derivedDataPath "$REPO_ROOT/.build/macos-derived-data" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -quiet && echo "  ✓ First build successful" || echo "  ⚠  Build had errors — check output above"
fi

# ── Optional: xcpretty ────────────────────────────────────────────────────────
echo ""
echo "Optional: xcpretty (nicer build output)"
if command -v xcpretty &>/dev/null; then
  echo "  ✓ xcpretty already installed"
else
  if command -v gem &>/dev/null; then
    read -p "  Install xcpretty via gem? (y/N) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      gem install xcpretty
      echo "  ✓ xcpretty installed"
    fi
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "Setup complete."
echo ""
echo "From now on, build with:"
echo "  ./scripts/build-macos.sh          # debug build"
echo "  ./scripts/build-macos.sh --run    # debug build + launch"
echo "  ./scripts/build-macos.sh --release --archive  # distributable .app"
echo ""
