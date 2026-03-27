#!/usr/bin/env bash
# =============================================================================
# tailscale-ssh-lockdown.sh
#
# Restricts macOS SSHD to listen only on the Tailscale interface.
#
# WHY THIS IS NEEDED
# ------------------
# macOS SSH is managed by launchd, not started directly. This means:
#   - /etc/ssh/sshd_config is IGNORED for ListenAddress / Port
#   - The socket binding is controlled by the launchd plist
#   - /System/Library/LaunchDaemons/ssh.plist is on the sealed system
#     volume and cannot be edited (even with sudo) on macOS Big Sur+
#
# THE FIX
# -------
# Create /Library/LaunchDaemons/com.openssh.sshd.plist (same Label as the
# system plist) with SockNodeName set to the Tailscale IP. launchd will use
# this override instead of the sealed system copy.
#
# Then:
#   sudo launchctl bootout system/com.openssh.sshd     # unload system copy
#   sudo launchctl bootstrap system <our plist>         # load our override
#
# To UNDO / restore SSH on all interfaces:
#   sudo launchctl bootout system/com.openssh.sshd
#   sudo rm /Library/LaunchDaemons/com.openssh.sshd.plist
#   sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
#
# Usage:
#   sudo ./scripts/tailscale-ssh-lockdown.sh            # apply lockdown
#   sudo ./scripts/tailscale-ssh-lockdown.sh --undo     # restore default
# =============================================================================

set -euo pipefail

PLIST="/Library/LaunchDaemons/com.openssh.sshd.plist"
SYSTEM_PLIST="/System/Library/LaunchDaemons/ssh.plist"
LABEL="com.openssh.sshd"

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "❌  Run with sudo: sudo $0 $*"
  exit 1
fi

# ── Undo mode ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--undo" ]]; then
  echo "→  Removing Tailscale SSH lockdown..."
  launchctl bootout system/$LABEL 2>/dev/null || true
  rm -f "$PLIST"
  launchctl bootstrap system "$SYSTEM_PLIST"
  echo "✓  SSH restored — listening on all interfaces"
  echo "   (Re-enable via System Settings → General → Sharing → Remote Login)"
  exit 0
fi

# ── Detect Tailscale IP ───────────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
  echo "❌  tailscale CLI not found. Install from https://tailscale.com/download"
  exit 1
fi

TS_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$TS_IP" ]]; then
  echo "❌  Could not get Tailscale IP. Is Tailscale connected?"
  exit 1
fi

echo "→  Tailscale IP: $TS_IP"

# ── Write the override plist ──────────────────────────────────────────────────
echo "→  Writing $PLIST..."
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openssh.sshd</string>
    <key>Program</key>
    <string>/usr/libexec/sshd-keygen-wrapper</string>
    <key>ProgramArguments</key>
    <array>
        <string>sshd-keygen-wrapper</string>
    </array>
    <key>Sockets</key>
    <dict>
        <key>Listeners</key>
        <dict>
            <key>SockNodeName</key>
            <string>${TS_IP}</string>
            <key>SockServiceName</key>
            <string>ssh</string>
            <key>Bonjour</key>
            <array>
                <string>ssh</string>
                <string>sftp-ssh</string>
            </array>
        </dict>
    </dict>
    <key>inetdCompatibility</key>
    <dict>
        <key>Wait</key>
        <false/>
        <key>Instances</key>
        <integer>42</integer>
    </dict>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>SHAuthorizationRight</key>
    <string>system.preferences</string>
    <key>POSIXSpawnType</key>
    <string>Interactive</string>
    <key>MaterializeDatalessFiles</key>
    <true/>
</dict>
</plist>
EOF

# ── Reload launchd ────────────────────────────────────────────────────────────
echo "→  Reloading SSH daemon..."
launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system "$PLIST"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "✓  SSH is now restricted to Tailscale only ($TS_IP:22)"
echo ""
echo "Listening sockets:"
lsof -nP -iTCP:22 -sTCP:LISTEN 2>/dev/null || true
echo ""
echo "To undo: sudo $0 --undo"
