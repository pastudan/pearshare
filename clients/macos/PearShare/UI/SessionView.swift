import SwiftUI

struct SessionView: View {
    let session: MediaSession
    let peer: PearPeer
    let onHangup: () -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isMuted = false

    var body: some View {
        ZStack {
            // Viewer: show remote video fullscreen
            if session.role == .viewer, let renderer = session.renderer {
                VideoDisplayView(renderer: renderer)
                    .ignoresSafeArea()
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
