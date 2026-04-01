import SwiftUI
import AppKit

// MARK: - ViewerControlPillPanel

/// Slim floating pill anchored to the top edge of the viewer's session window.
/// Positioned so 20 pt hangs above the window and 20 pt hangs below, centered horizontally.
/// AppDelegate keeps it repositioned on window move/resize.
final class ViewerControlPillPanel: NSPanel {

    static func make(debugInfo: SessionDebugInfo, onHangup: @escaping () -> Void) -> ViewerControlPillPanel {
        let p = ViewerControlPillPanel()
        let view = ViewerControlPillView(debugInfo: debugInfo, onHangup: onHangup)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        p.contentView = hosting
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return p
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // isMovableByWindowBackground is intentionally NOT set: AppKit's built-in drag
        // tracking loop only posts NSWindow.didMoveNotification after the drag ends, so
        // the session window wouldn't follow in real-time. Dragging is handled manually
        // with local NSEvent monitors in AppDelegate instead.
    }
}

// MARK: - ViewerControlPillView

struct ViewerControlPillView: View {
    @ObservedObject var debugInfo: SessionDebugInfo
    let onHangup: () -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isMuted = false
    @State private var showDebug = false

    var body: some View {
        HStack(spacing: 12) {
            Text(formattedDuration)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.black.opacity(0.7))

            Rectangle()
                .fill(.black.opacity(0.2))
                .frame(width: 1, height: 16)

            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted ? .red : .black.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute microphone" : "Mute microphone")

            Button {
                showDebug.toggle()
            } label: {
                Image(systemName: "ant.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(showDebug ? .white : .black.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(showDebug ? Color.black.opacity(0.35) : Color.black.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Session debug info")
            .popover(isPresented: $showDebug, arrowEdge: .bottom) {
                SessionDebugView(info: debugInfo)
            }

            Button(action: onHangup) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.red, in: Circle())
            }
            .buttonStyle(PillButtonStyle())
            .help("End session")
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 40)
        .background(
            Capsule()
                .fill(Color.pearGreen)
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

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
