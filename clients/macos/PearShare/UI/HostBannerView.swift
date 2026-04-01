import SwiftUI
import AppKit

let kHostBannerWindowTitle = "PearShare-HostBanner"

// MARK: - HostBannerWindow

/// Slim draggable floating banner shown on the host's screen during an active session.
/// Replaces the full session window for the host role — stays out of the way while
/// the host continues working, but provides obvious session controls.
final class HostBannerWindow: NSWindow {

    static func make(
        peer: PearPeer,
        debugInfo: SessionDebugInfo,
        onHangup: @escaping () -> Void,
        onInputToggled: @escaping (Bool) -> Void
    ) -> HostBannerWindow {
        let w = HostBannerWindow()
        let view = HostBannerView(peer: peer, debugInfo: debugInfo, onHangup: onHangup, onInputToggled: onInputToggled)
        w.title = kHostBannerWindowTitle
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        w.contentView = hosting
        // Without this the NSHostingView renders an opaque white/grey background,
        // causing a rectangular box around the capsule and blocking transparency.
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        if let screen = NSScreen.main {
            let x = screen.frame.minX + (screen.frame.width - 460) / 2
            let y = screen.visibleFrame.minY + 60
            w.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            w.center()
        }
        return w
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

// MARK: - HostBannerView

struct HostBannerView: View {
    let peer: PearPeer
    @ObservedObject var debugInfo: SessionDebugInfo
    let onHangup: () -> Void
    let onInputToggled: (Bool) -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isMuted = true
    @State private var isInputEnabled = false
    @State private var showDebug = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onHangup) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
            }
            .buttonStyle(BannerButtonStyle())
            .help("End session")
            .padding(.trailing, 10)

            Divider()
                .frame(height: 18)
                .background(.black.opacity(0.25))
                .padding(.trailing, 10)

            Text(formattedDuration)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.black.opacity(0.7))
                .padding(.trailing, 10)

            Divider()
                .frame(height: 18)
                .background(.black.opacity(0.25))
                .padding(.trailing, 10)

            HStack(spacing: 5) {
                Circle()
                    .fill(.black.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text(peer.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                showDebug.toggle()
            } label: {
                Image(systemName: "ant.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(showDebug ? .white : .black.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(showDebug ? Color.black.opacity(0.35) : Color.black.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Session debug info")
            .popover(isPresented: $showDebug, arrowEdge: .bottom) {
                SessionDebugView(info: debugInfo)
            }
            .padding(.trailing, 6)

            // K&M sharing toggle — off by default; host must opt in
            Button {
                isInputEnabled.toggle()
                onInputToggled(isInputEnabled)
            } label: {
                Image(systemName: isInputEnabled ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 11))
                    .foregroundStyle(isInputEnabled ? .white : .black.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(isInputEnabled ? Color.blue : .black.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isInputEnabled
                  ? "Keyboard & mouse sharing on — click to disable"
                  : "Enable keyboard & mouse sharing with \(peer.displayName)")
            .padding(.trailing, 6)

            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isMuted ? .red : .black.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute microphone" : "Mute microphone")
        }
        .padding(.horizontal, 14)
        .frame(width: 460, height: 52)
        .background(
            Capsule()
                .fill(Color.pearGreen.opacity(0.90))
        )
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in elapsed += 1 }
    }

    private var formattedDuration: String {
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

private struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
