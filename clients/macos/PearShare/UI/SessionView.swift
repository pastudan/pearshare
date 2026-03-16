import SwiftUI

// MARK: - RemoteControlState
//
// Bridges ControlChannel callbacks into SwiftUI via ObservableObject.
// AppDelegate creates one instance per session and wires it to ctrl.onRemoteActivity.

final class RemoteControlState: ObservableObject {
    /// True when the remote peer has sent a control event recently (host side).
    @Published var remoteIsActive: Bool = false
    private var activityTimer: Timer?

    func markActive() {
        DispatchQueue.main.async { [weak self] in
            self?.remoteIsActive = true
            self?.activityTimer?.invalidate()
            // Badge fades after 2 seconds of inactivity
            self?.activityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.remoteIsActive = false
            }
        }
    }
}

// MARK: - SessionView

struct SessionView: View {
    let session: MediaSession
    let peer: PearPeer
    let onHangup: () -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isMuted = false

    // Passed in by AppDelegate; drives the remote-control badge on the host toolbar
    @ObservedObject var remoteControlState: RemoteControlState

    init(session: MediaSession, peer: PearPeer,
         remoteControlState: RemoteControlState = RemoteControlState(),
         onHangup: @escaping () -> Void) {
        self.session = session
        self.peer = peer
        self.remoteControlState = remoteControlState
        self.onHangup = onHangup
    }

    var body: some View {
        ZStack {
            // Always dark background
            Color.black.ignoresSafeArea()

            if session.role == .viewer, let renderer = session.renderer {
                // Viewer: remote video fullscreen
                VideoDisplayView(renderer: renderer)
                    .ignoresSafeArea()
            } else if session.role == .host {
                // Host: show a subtle "sharing" indicator
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Sharing your screen with \(peer.displayName)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Floating toolbar pinned to top
            VStack {
                toolbar
                    .padding(.top, 12)
                Spacer()
            }
        }
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Session duration
            Label(formattedDuration, systemImage: "video.fill")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)

            Divider()
                .frame(height: 16)
                .background(.white.opacity(0.3))

            // Peer name
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(peer.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Role indicator
            Text(session.role == .host ? "Sharing" : "Viewing")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)

            // Remote control activity badges
            remoteControlBadge

            // Mute
            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(isMuted ? .red : .white)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.12), in: Circle())

            // Hangup
            Button(action: onHangup) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .background(.red, in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    // MARK: - Remote control badge

    @ViewBuilder
    private var remoteControlBadge: some View {
        switch session.role {
        case .host:
            // Teal badge appears when the remote peer is actively sending input (last-touch model)
            if remoteControlState.remoteIsActive {
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.caption2)
                    Text("Remote")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(red: 0.0, green: 0.78, blue: 0.75).opacity(0.8), in: Capsule())
                .foregroundStyle(.black)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .animation(.easeInOut(duration: 0.2), value: remoteControlState.remoteIsActive)
            }
        case .viewer:
            // Viewer always shows "Controlling" so they know their input is live
            HStack(spacing: 4) {
                Image(systemName: "cursorarrow")
                    .font(.caption2)
                Text("Controlling")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(red: 0.0, green: 0.78, blue: 0.75).opacity(0.6), in: Capsule())
            .foregroundStyle(.black)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private var formattedDuration: String {
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
