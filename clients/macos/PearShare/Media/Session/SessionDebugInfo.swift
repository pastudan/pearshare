import Foundation
import AppKit
import SwiftUI
import os

// MARK: - Thread-safe counters (incremented from encoder / decoder callbacks off main actor)

private struct PipelineCounters {
    var frames: Int = 0
    var bytes:  Int = 0
}

// MARK: - SessionDebugInfo

/// Live pipeline stats surfaced in the debug overlay on both host and viewer pills.
/// Published on @MainActor; raw counters are incremented from background queues via
/// the nonisolated recordFrame() / recordBytes() methods.
@MainActor
final class SessionDebugInfo: ObservableObject {

    // MARK: Stream
    @Published var encodeWidth:  Int = 0
    @Published var encodeHeight: Int = 0
    @Published var physicalWidth:  Int = 0
    @Published var physicalHeight: Int = 0
    @Published var targetFPS:          Double = 0
    @Published var measuredFPS:        Double = 0
    @Published var targetBitrateMbps:  Double = 0
    /// Host: Mbps encoded+sent.  Viewer: Mbps received over UDP.
    @Published var measuredBitrateMbps: Double = 0

    // MARK: Local displays
    @Published var localScreens: [(width: Int, height: Int)] = []

    // MARK: Tailscale (self node)
    @Published var tailscaleHostname: String = "…"
    @Published var tailscaleIP:       String = "…"
    @Published var tailscaleOnline:   Bool   = false

    // MARK: Peer
    @Published var peerIP:       String = "—"
    @Published var peerHostname: String = "—"

    // MARK: Session meta
    @Published var roleLabel: String = ""

    // MARK: - Thread-safe counters
    private let countersLock = OSAllocatedUnfairLock(initialState: PipelineCounters())

    private var statsTimer: Timer?
    private var streamDimsUpdated = false

    // MARK: - Lifecycle

    func setStreamInfo(
        encodeWidth: Int, encodeHeight: Int,
        physicalWidth: Int, physicalHeight: Int,
        targetFPS: Double,
        targetBitrateMbps: Double
    ) {
        self.encodeWidth       = encodeWidth
        self.encodeHeight      = encodeHeight
        self.physicalWidth     = physicalWidth
        self.physicalHeight    = physicalHeight
        self.targetFPS         = targetFPS
        self.targetBitrateMbps = targetBitrateMbps
    }

    func start() {
        localScreens = NSScreen.screens.map { s in
            let f = s.backingScaleFactor
            return (Int(s.frame.width * f), Int(s.frame.height * f))
        }
        Task { await loadTailscale() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Called once when the first decoded frame arrives (viewer side) to fill in stream dimensions.
    func updateStreamDimensions(width: Int, height: Int) {
        guard !streamDimsUpdated else { return }
        streamDimsUpdated = true
        encodeWidth  = width
        encodeHeight = height
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - Nonisolated recording (called from encoder/decoder background queues)

    nonisolated func recordFrame() {
        countersLock.withLock { $0.frames += 1 }
    }

    nonisolated func recordBytes(_ count: Int) {
        countersLock.withLock { $0.bytes += count }
    }

    // MARK: - Private

    private func tick() {
        let snap = countersLock.withLock { state -> PipelineCounters in
            let s = state; state = PipelineCounters(); return s
        }
        measuredFPS         = Double(snap.frames)
        measuredBitrateMbps = Double(snap.bytes * 8) / 1_000_000.0
    }

    private func loadTailscale() async {
        guard let status = try? await TailscaleClient().status() else {
            tailscaleHostname = "unavailable"
            tailscaleIP       = "—"
            tailscaleOnline   = false
            return
        }
        tailscaleHostname = status.selfNode.hostName
        tailscaleIP       = status.selfNode.tailscaleIPs?.first ?? "—"
        tailscaleOnline   = status.selfNode.online ?? false
    }
}

// MARK: - SessionDebugView

/// Compact debug panel shown in the popover triggered by the bug button on both pills.
struct SessionDebugView: View {
    @ObservedObject var info: SessionDebugInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Header ────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Text(info.roleLabel.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(info.tailscaleOnline ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text("tailscale \(info.tailscaleOnline ? "online" : "offline")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // ── Stream ────────────────────────────────────────────────────────
            debugSection("STREAM") {
                if info.encodeWidth > 0 {
                    debugRow("stream", "\(info.encodeWidth) × \(info.encodeHeight)")
                }
                if info.physicalWidth > 0 {
                    debugRow("physical", "\(info.physicalWidth) × \(info.physicalHeight)")
                }
                debugRow("fps", info.targetFPS > 0
                    ? String(format: "%.1f / %d target", info.measuredFPS, Int(info.targetFPS))
                    : String(format: "%.1f", info.measuredFPS))
                debugRow("bitrate", info.targetBitrateMbps > 0
                    ? String(format: "%.2f / %.0f Mbps", info.measuredBitrateMbps, info.targetBitrateMbps)
                    : String(format: "%.2f Mbps (uncapped)", info.measuredBitrateMbps))
            }

            // ── Local displays ────────────────────────────────────────────────
            debugSection("DISPLAYS (\(info.localScreens.count))") {
                ForEach(Array(info.localScreens.enumerated()), id: \.offset) { idx, s in
                    debugRow("\(idx + 1)", "\(s.width) × \(s.height)")
                }
            }

            // ── Network ───────────────────────────────────────────────────────
            debugSection("NETWORK") {
                debugRow("peer ip", info.peerIP)
                if !info.peerHostname.isEmpty && info.peerHostname != "—" && info.peerHostname != info.peerIP {
                    debugRow("peer", info.peerHostname)
                }
            }

            // ── Tailscale self ────────────────────────────────────────────────
            debugSection("TAILSCALE") {
                debugRow("self", info.tailscaleHostname)
                debugRow("ip", info.tailscaleIP)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private func debugSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 1)
            content()
        }
    }

    @ViewBuilder
    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}
