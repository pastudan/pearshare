---
name: PearShare MVP Plan
overview: Build PearShare MVP as a native macOS Swift/SwiftUI app — a Tailscale-native screen sharing and remote collaboration tool in the spirit of ScreenHero. The protocol will be documented for future Windows compatibility. No WebRTC, no relay infrastructure — all transport runs peer-to-peer over Tailscale's WireGuard tunnels.
todos:
  - id: phase1-tailscale
    content: "Phase 1: Tailscale LocalAPI client, peer discovery, UDP presence beacon, TCP signaling protocol (ring/accept/reject/hangup)"
    status: pending
  - id: phase2-video
    content: "Phase 2: ScreenCaptureKit capture pipeline, VideoToolbox H.264 encoder/decoder, RTP packetizer, UDP video stream"
    status: pending
  - id: phase3-audio
    content: "Phase 3: AVAudioEngine capture/playback, swift-opus integration, RTP audio stream"
    status: pending
  - id: phase4-input
    content: "Phase 4: CGEvent injection (host), CGEvent tap (viewer), input serialization over control channel, dual cursor Metal overlay"
    status: pending
  - id: phase5-ui
    content: "Phase 5: Menu bar app, contact list with presence, incoming ring HUD, session toolbar UI"
    status: pending
  - id: phase6-permissions
    content: "Phase 6: Permissions onboarding flow (Screen Recording, Accessibility, Microphone, Local Network)"
    status: pending
isProject: false
---

# PearShare MVP — Implementation Plan

## Stack Decision

- **UI**: SwiftUI + AppKit (hybrid where needed for menu bar, overlays)
- **Screen capture**: ScreenCaptureKit (macOS 13+)
- **Video encode/decode**: VideoToolbox (H.264, hardware-accelerated)
- **Audio**: AVAudioEngine + swift-opus (Opus codec)
- **Networking**: Network.framework (NWConnection for UDP/TCP)
- **Tailscale integration**: Tailscale LocalAPI over Unix domain socket
- **Minimum macOS**: 13.0 (Ventura) — required for ScreenCaptureKit stability

---

## Project Structure

```
PearShare/
├── PearShare.xcodeproj
├── PearShare/
│   ├── App/
│   │   ├── PearShareApp.swift          # App entry, menu bar item
│   │   └── AppDelegate.swift
│   ├── Tailscale/
│   │   ├── TailscaleClient.swift       # LocalAPI Unix socket client
│   │   ├── PeerDiscovery.swift         # Poll LocalAPI + UDP beacon
│   │   └── Models/TailscalePeer.swift
│   ├── Signaling/
│   │   ├── SignalingServer.swift        # TCP listener (incoming rings)
│   │   ├── SignalingClient.swift        # TCP dialer (outgoing rings)
│   │   └── SignalingProtocol.swift     # Message types (RING, ACCEPT, etc.)
│   ├── Media/
│   │   ├── ScreenCapture/
│   │   │   ├── ScreenCaptureManager.swift
│   │   │   └── WindowPicker.swift      # SCContentSharingPicker wrapper
│   │   ├── VideoCodec/
│   │   │   ├── H264Encoder.swift       # VideoToolbox VTCompressionSession
│   │   │   ├── H264Decoder.swift       # VideoToolbox VTDecompressionSession
│   │   │   └── RTPPacketizer.swift     # NAL unit → RTP framing
│   │   ├── Audio/
│   │   │   ├── AudioCaptureEngine.swift
│   │   │   ├── AudioPlaybackEngine.swift
│   │   │   └── OpusCodec.swift         # swift-opus wrapper
│   │   └── Session/
│   │       ├── MediaSession.swift       # Owns encoder + decoder + streams
│   │       └── StreamMultiplexer.swift  # Single UDP socket, stream IDs
│   ├── RemoteInput/
│   │   ├── InputInjector.swift         # CGEvent injection (host side)
│   │   ├── InputCapture.swift          # CGEvent tap (viewer side)
│   │   └── CursorOverlay.swift         # Metal layer, remote cursor rendering
│   ├── Permissions/
│   │   ├── PermissionManager.swift
│   │   └── OnboardingView.swift        # Step-by-step permission flow
│   └── UI/
│       ├── ContactListView.swift        # Main window: peers + presence
│       ├── IncomingRingView.swift       # HUD notification
│       ├── SessionView.swift            # Active session chrome
│       └── StatusBarController.swift   # NSStatusItem menu
└── PearShareTests/
```

---

## Phase 1 — Foundation (Tailscale + Signaling)

### Tailscale LocalAPI Client

Call the Tailscale daemon's local HTTP-over-Unix-socket API. No API key needed.

```swift
// TailscaleClient.swift — key pattern
let socketPath = "/var/run/tailscale/tailscaled.sock"
// Use URLSession with custom URLProtocol or Network.framework NWConnection
// to connect to Unix domain socket and issue HTTP GET /localapi/v0/status
```

Response shape (relevant fields):

```json
{
  "Self": { "HostName": "alice-mac", "TailscaleIPs": ["100.x.x.x"] },
  "Peer": {
    "<nodekey>": {
      "HostName": "bob-linux",
      "TailscaleIPs": ["100.y.y.y"],
      "Online": true
    }
  }
}
```

### PearShare Presence Beacon

On startup, broadcast a UDP beacon on port **5533** so peers know PearShare is running (Tailscale only tells you the device is online, not whether PearShare is running):

```
Beacon payload (JSON, sent every 10s):
{ "v": 1, "type": "presence", "status": "available" }
// status: "available" | "busy" | "dnd"
```

### Signaling Protocol (TCP, port 5534)

```
→ RING    { "from": "alice-mac", "displayName": "Alice", "version": "1.0.0" }
← ACCEPT  { "sessionId": "uuid", "videoPort": 5535, "audioPort": 5536, "controlPort": 5537 }
← REJECT  { "reason": "declined" | "busy" }
← RING    (simultaneous ring — both sides rang at the same time)
→ HANGUP  {}
```

All messages are newline-delimited JSON over a persistent TCP connection for the session lifetime.

---

## Phase 2 — Video Pipeline

### Capture → Encode

```
ScreenCaptureKit                   VideoToolbox
SCStreamOutput                     VTCompressionSession
  .captureOutput(_:didOutputSampleBuffer:)
     │
     ▼
  CMSampleBuffer (CVPixelBuffer, 420v)
     │
     ▼
  VTCompressionSession.encodeFrame(...)
     │
     ▼
  CMBlockBuffer (H.264 annexb NAL units)
     │
     ▼
  RTPPacketizer → NWConnection UDP → Tailscale tunnel
```

VideoToolbox key settings for low latency:

- `kVTCompressionPropertyKey_RealTime = true`
- `kVTCompressionPropertyKey_AllowFrameReordering = false` (no B-frames)
- `kVTCompressionPropertyKey_AverageBitRate = 4_000_000` (adjustable)
- `kVTCompressionPropertyKey_ProfileLevel = kVTProfileLevel_H264_High_AutoLevel`

### Decode → Display

```
UDP recv → RTP depacketizer → NAL unit reassembly
  → VTDecompressionSession.decodeFrame(...)
  → CVPixelBuffer
  → CALayer / Metal MTKView
```

Use a small jitter buffer (~3 frames / 100ms) to smooth packet reordering before passing to decoder.

---

## Phase 3 — Audio Pipeline

```
AVAudioEngine (input tap, 48kHz, mono for voice)
  → PCM buffer (1024 samples = ~21ms)
  → OpusEncoder.encode() → opus packet bytes
  → RTP frame → UDP → Tailscale

UDP recv → RTP depacketizer → opus packet
  → OpusDecoder.decode() → PCM buffer
  → AVAudioEngine (output node, playerNode)
```

Dependency: `swift-opus` via Swift Package Manager — `https://github.com/alta/swift-opus`

Echo cancellation: use `kAudioDevicePropertyVoiceActivityDetectionEnabled` + AVAudioEngine's built-in voice processing mode (`setVoiceProcessingEnabled(true)` on the input node, macOS 14+).

---

## Phase 4 — Remote Input

### Host Side (Input Injector)

Requires Accessibility permission. Receives serialized events over the control channel UDP port and injects via CGEvent:

```swift
// Mouse move
let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: translatedPoint, mouseButton: .left)
event?.post(tap: .cgAnnotatedSessionEventTap)

// Key press
let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
event?.flags = CGEventFlags(rawValue: modifierFlags)
event?.post(tap: .cgAnnotatedSessionEventTap)
```

Coordinate translation: always transmit normalized (0.0–1.0) relative to the captured display bounds. Host maps back to absolute screen coordinates.

### Viewer Side (Input Capture)

Install a `CGEventTap` at `.cgAnnotatedSessionEventTap` level to intercept mouse/keyboard while in session:

```swift
let eventMask: CGEventMask = [.mouseMoved, .leftMouseDown, .leftMouseUp,
                               .rightMouseDown, .rightMouseUp, .keyDown, .keyUp,
                               .scrollWheel].reduce(0) { $0 | (1 << $1.rawValue) }
```

Serialize to control channel:

```json
{ "type": "mouse", "x": 0.452, "y": 0.331, "event": "move" }
{ "type": "key",   "keyCode": 36,  "modifiers": 131072, "down": true }
```

### Dual Cursor Overlay (ScreenHero Mode)

Render the remote user's cursor as an overlay on top of the decoded video frame using a transparent `NSWindow` (`.borderless`, `.nonactivating`, level `.screenSaver`) positioned over the session display. Draw a colored ring + cursor icon using Core Graphics or SwiftUI Canvas, updated at the video frame rate.

---

## Phase 5 — UI

### Menu Bar App

PearShare lives in the menu bar (no Dock icon in normal operation). `NSStatusItem` with a pear icon. Clicking opens the contact list popover.

### Contact List

- Shows all Tailscale peers that are online AND running PearShare (beacon received)
- Presence dot: green (available), yellow (busy), gray (offline)
- Click a peer → ring them
- Shows your own status with a toggle

### Incoming Ring

Full-screen-adjacent HUD notification (`NSPanel`, `.hudWindow` style) with caller name, Accept / Decline buttons, and a subtle ring animation. Auto-declines after 30s.

### Session View

Minimal chrome: a thin floating toolbar showing session duration, mute, hang up, "swap control" button, and the remote cursor color legend. The actual content fills the screen (the decoded video layer).

---

## Phase 6 — Permissions Onboarding

On first launch, walk through in order:

1. Screen Recording — open System Settings deep link + poll `CGPreflightScreenCaptureAccess()`
2. Accessibility — `AXIsProcessTrustedWithOptions` + prompt + re-check loop
3. Microphone — `AVCaptureDevice.requestAccess(for: .audio)`
4. Local Network — triggered automatically on first UDP send; explain it in the UI

Each step: show what it's for, a "Grant" button that opens the right System Settings pane, and a "Check again" button after they've granted it.

---

## Wire Protocol Summary (for future Windows client)

| Port | Protocol | Purpose                                              |
| ---- | -------- | ---------------------------------------------------- |
| 5533 | UDP      | Presence beacon (broadcast/unicast, 10s interval)    |
| 5534 | TCP      | Call signaling (ring/accept/reject/hangup)           |
| 5535 | UDP      | Video RTP stream                                     |
| 5536 | UDP      | Audio RTP stream                                     |
| 5537 | UDP      | Control channel (input events, cursor pos, metadata) |

All traffic is peer-to-peer over the existing Tailscale WireGuard tunnel. No PearShare servers involved.

---

## Dependencies (Swift Package Manager)

- `https://github.com/alta/swift-opus` — Opus codec bindings
- No other external dependencies needed for MVP (VideoToolbox, Network.framework, ScreenCaptureKit, AVFoundation are all Apple system frameworks)

---

## Token Budget (Phased)

- Phase 1 (Tailscale + Signaling): ~60-80k tokens
- Phase 2 (Video pipeline): ~80-100k tokens
- Phase 3 (Audio pipeline): ~40-60k tokens
- Phase 4 (Remote input + dual cursors): ~80-100k tokens
- Phase 5 (UI): ~60-80k tokens
- Phase 6 (Permissions onboarding): ~20-30k tokens
- **Total: ~340-450k tokens**

---

## Build Order Recommendation

1. Tailscale LocalAPI + presence beacon — you can see peers immediately
2. Signaling (ring/accept) — you can call peers, even with no media yet
3. Video pipeline (capture + encode + decode + display) — one direction first
4. Audio pipeline
5. Remote input (mouse first, then keyboard)
6. Dual cursor overlay
7. Full UI polish + permissions onboarding
