# PearShare — macOS Client

Native Swift/SwiftUI macOS application. Minimum macOS 13.0 (Ventura).

## Building

1. Open `PearShare.xcodeproj` in Xcode 15+
2. Select the `PearShare` scheme
3. Build & Run (`Cmd+R`)

On first run, macOS will prompt for:
- **Screen Recording** — required for future screen share (Phase 2)
- **Accessibility** — required for remote input injection (Phase 4)
- **Microphone** — required for audio (Phase 3)
- **Local Network** — required for UDP beacon discovery

Grant all four in System Settings > Privacy & Security.

## Phase 1 Features (this branch)

- Reads your Tailscale peer list via the LocalAPI Unix socket (`/var/run/tailscale/tailscaled.sock`)
- Broadcasts a UDP presence beacon on port 5533 every 10 seconds to all online Tailscale peers
- Receives beacons from peers running PearShare — they appear in the menu bar contact list
- Supports ringing a peer (TCP signaling on port 5534) and accepting/declining incoming rings
- Lives in the menu bar — no Dock icon

## Prerequisites

- [Tailscale](https://tailscale.com) installed and authenticated (`tailscale up`)
- Xcode 15+
- macOS 13.0+

## Architecture

See the root `protocol/PROTOCOL.md` for the wire protocol spec shared with the Windows client.

```
App/
├── PearShareApp.swift       — @main entry, menu bar setup
└── AppDelegate.swift        — wires services together, manages windows

Tailscale/
├── TailscaleClient.swift    — HTTP over Unix socket → /localapi/v0/status
├── Models.swift             — TailscaleStatus, PearPeer, etc.
└── PeerDiscovery.swift      — polls LocalAPI + sends/receives UDP beacons

Signaling/
├── SignalingProtocol.swift  — message types (RING, ACCEPT, REJECT, HANGUP)
├── SignalingServer.swift    — TCP listener on port 5534 (incoming rings)
└── SignalingClient.swift    — TCP dialer (outgoing rings) + response handlers

UI/
├── ContactListView.swift    — menu bar popover: peer list with presence dots
└── IncomingRingView.swift   — floating HUD for incoming ring notifications
```
