# PearShare Wire Protocol v1

This document defines the complete wire protocol for PearShare. Both the macOS and Windows clients implement this spec. The goal is that any two conforming clients can interoperate regardless of platform.

## Port Assignments

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 5533 | UDP | Broadcast / unicast | Presence beacon |
| 5534 | TCP | Bidirectional | Call signaling |
| 5535 | UDP | Host → Viewer | Video RTP stream |
| 5536 | UDP | Bidirectional | Audio RTP stream |
| 5537 | UDP | Bidirectional | Control channel |

All communication is peer-to-peer over the Tailscale WireGuard tunnel. No PearShare servers are involved.

---

## 1. Presence Beacon (UDP 5533)

Each running PearShare instance broadcasts a JSON payload every **10 seconds** to its known Tailscale peers (unicast to each peer's Tailscale IP). This lets peers distinguish "Tailscale device online" from "PearShare is actually running on that device."

### Payload

```json
{
  "v": 1,
  "type": "presence",
  "status": "available",
  "displayName": "Alice's MacBook Pro",
  "platform": "macos",
  "appVersion": "0.1.0"
}
```

### Fields

| Field | Type | Values |
|-------|------|--------|
| `v` | int | Protocol version. Currently `1`. |
| `type` | string | Always `"presence"` for beacon packets. |
| `status` | string | `"available"` \| `"busy"` \| `"dnd"` |
| `displayName` | string | Human-readable device/user name. |
| `platform` | string | `"macos"` \| `"windows"` \| `"linux"` |
| `appVersion` | string | Semver string. |

A peer is considered **offline** (PearShare not running) if no beacon is received within **30 seconds**.

---

## 2. Call Signaling (TCP 5534)

The caller opens a TCP connection to the callee's Tailscale IP on port 5534. Messages are **newline-delimited JSON** (`\n` terminated). The connection stays open for the lifetime of the call.

### Message Types

#### RING (caller → callee)
```json
{
  "type": "ring",
  "from": "alice-macbook",
  "displayName": "Alice",
  "tailscaleIP": "100.x.x.x",
  "version": "1.0.0"
}
```

#### ACCEPT (callee → caller)
```json
{
  "type": "accept",
  "sessionId": "550e8400-e29b-41d4-a716-446655440000",
  "videoPort": 5535,
  "audioPort": 5536,
  "controlPort": 5537
}
```

#### REJECT (callee → caller)
```json
{
  "type": "reject",
  "reason": "declined"
}
```

Reason values: `"declined"` | `"busy"`

#### HANGUP (either direction)
```json
{
  "type": "hangup"
}
```

#### BUSY (callee → caller, sent immediately if callee is in a session)
```json
{
  "type": "busy"
}
```

### Call Flow

```
Caller                          Callee
  |                               |
  |-- TCP connect port 5534 ----> |
  |-- RING ---------------------->|
  |                               | (shows incoming ring UI, 30s timeout)
  |<----- ACCEPT ----------------|   or
  |<----- REJECT ----------------|   or
  |<----- BUSY ------------------|
  |                               |
  | (if ACCEPT: open media ports) |
  |<=== video/audio/control ======|
  |                               |
  |-- HANGUP -------------------->|   or
  |<----- HANGUP -----------------|
  |                               |
  | (TCP connection closed)       |
```

Auto-decline: if no user action within 30 seconds, send `REJECT { reason: "declined" }`.

---

## 3. Video Stream (UDP 5535)

H.264 Annex B NAL units carried in a minimal RTP-like framing.

### Packet Format

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Version(8)   |  StreamID(8)  |        SequenceNumber(16)     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Timestamp(32)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Flags(8)     |  Reserved(24)                                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Payload ...                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **Version**: `1`
- **StreamID**: `1` = video, `2` = audio, `3` = control
- **SequenceNumber**: monotonically increasing per stream, wraps at 65535
- **Timestamp**: microseconds since session start (32-bit, wraps ~71 minutes)
- **Flags**: `0x01` = keyframe, `0x02` = last packet of frame, `0x04` = retransmit

### Video Codec

- Codec: H.264 (baseline profile for MVP; negotiate H.265 in v2)
- No B-frames (`AllowFrameReordering = false`)
- Real-time mode
- Target bitrate: 4 Mbps default, adjustable
- Frame rate: 30fps default

---

## 4. Audio Stream (UDP 5536)

Opus-encoded audio using the same packet framing as video (StreamID = 2).

- Sample rate: 48000 Hz
- Channels: 1 (mono) for voice
- Frame size: 20ms (960 samples)
- Application mode: VOIP
- Bitrate: 32 kbps

---

## 5. Control Channel (UDP 5537)

JSON payloads using the same packet framing (StreamID = 3). Carries input events and cursor state.

### Mouse Move
```json
{ "t": "mm", "x": 0.4521, "y": 0.3317 }
```
Coordinates are normalized 0.0–1.0 relative to the shared display bounds.

### Mouse Button
```json
{ "t": "mb", "x": 0.4521, "y": 0.3317, "btn": 0, "dn": true }
```
`btn`: 0 = left, 1 = right, 2 = middle

### Mouse Scroll
```json
{ "t": "ms", "dx": 0.0, "dy": -3.0 }
```

### Key Event
```json
{ "t": "ke", "kc": 36, "mod": 131072, "dn": true }
```
`kc` = platform keycode (macOS CGKeyCode / Windows VK_*), `mod` = modifier flags bitmask

### Cursor Position Broadcast (for dual-cursor overlay)
```json
{ "t": "cp", "x": 0.4521, "y": 0.3317, "peer": "alice-macbook" }
```

---

## Version Negotiation

Future versions will add a capability negotiation step after ACCEPT. For v1, both sides are assumed to support H.264 + Opus + the above control protocol. Version mismatches should surface in the `appVersion` field of the presence beacon.
