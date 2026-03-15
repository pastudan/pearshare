# PearShare — Windows Client

> Status: Planned (fast follow after macOS MVP)

The Windows client will be a native C++ application using Win32/WinUI 3, implementing the same wire protocol as the macOS client (see `../../protocol/PROTOCOL.md`).

## Planned Stack

- **UI**: WinUI 3 (Windows App SDK)
- **Screen capture**: DXGI Desktop Duplication API
- **Video encode/decode**: Media Foundation + MFT H.264 hardware codec
- **Audio**: WASAPI + Opus
- **Networking**: Winsock2 / Windows.Networking
- **Tailscale**: LocalAPI over named pipe (`\\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled`)

## Protocol Compatibility

The Windows client will be fully interoperable with the macOS client via the shared protocol in `protocol/PROTOCOL.md`. A macOS user can ring a Windows user and vice versa.

## Tailscale Daemon Socket (Windows)

On Windows, Tailscale exposes its LocalAPI over a named pipe rather than a Unix socket:

```
\\.\pipe\ProtectedPrefix\Administrators\Tailscale\tailscaled
```

HTTP requests are issued the same way — GET /localapi/v0/status — but over the named pipe.
