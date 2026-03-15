# PearShare

The spiritual successor to ScreenHero. An open-source, Tailscale-native remote collaboration tool — see your teammates, ring them, share your screen, and drive together with dual cursors.

No relay servers. No WebRTC. No NAT traversal headaches. If you can see a device in your Tailscale tailnet, you can PearShare with it.

## Monorepo Structure

```
pearshare/
├── clients/
│   ├── macos/          # Native Swift/SwiftUI macOS app (MVP)
│   └── windows/        # Native C++/WinUI Windows app (fast follow)
├── protocol/           # Wire protocol specification (shared, platform-agnostic)
├── docs/               # Architecture docs, screenshots
└── scripts/            # Build, release, dev tooling
```

## How It Works

PearShare uses Tailscale as its network layer. If a device is visible in your org's Tailscale ACL and is running PearShare, it shows up as a peer. No separate accounts, no friend requests — your Tailscale org membership is your identity.

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 5533 | UDP | Presence beacon (10s heartbeat) |
| 5534 | TCP | Call signaling (ring / accept / reject / hangup) |
| 5535 | UDP | Video RTP stream |
| 5536 | UDP | Audio RTP stream |
| 5537 | UDP | Control channel (remote input events, cursor positions) |

All traffic is peer-to-peer over Tailscale's WireGuard tunnels.

## Prerequisites

- [Tailscale](https://tailscale.com) installed and logged in
- macOS 13.0+ (Ventura) for the macOS client
- Xcode 15+ (for building the macOS client)

## Building

### First time (one-time setup)

```bash
./scripts/setup.sh
```

This installs prerequisites, switches to the Xcode toolchain, and walks you through the one GUI step required to set your signing team. After that, everything is headless.

### Every build after that

```bash
./scripts/build-macos.sh            # debug build
./scripts/build-macos.sh --run      # debug build + launch the app
./scripts/build-macos.sh --clean    # clean + debug build
./scripts/build-macos.sh --release --archive  # distributable .app → .build/PearShare-export/
```

See `clients/macos/README.md` for more details.

## Status

- [x] Phase 1: Tailscale peer discovery + call signaling
- [ ] Phase 2: Screen capture + video pipeline
- [ ] Phase 3: Audio pipeline
- [ ] Phase 4: Remote input + dual cursors
- [ ] Phase 5: Full UI polish
- [ ] Phase 6: Windows client
