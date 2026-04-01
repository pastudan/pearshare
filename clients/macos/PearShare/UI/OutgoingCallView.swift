import SwiftUI

/// Floating window shown to the caller while waiting for the remote peer to accept.
/// Displays the peer name, intent context, a live elapsed timer, and a cancel button.
struct OutgoingCallView: View {
    let peer: PearPeer
    /// "share" = we are offering our screen; "request" = we are asking them to share theirs.
    let intent: String
    let onCancel: () -> Void

    @State private var elapsed: Int = 0
    @State private var callTimer: Timer?
    @State private var pulse = false

    private var isRequest: Bool { intent == "request" }

    var body: some View {
        VStack(spacing: 16) {
            // Pulsing avatar ring
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(pulse ? 0.15 : 0.45), lineWidth: pulse ? 18 : 4)
                    .frame(width: 64, height: 64)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: isRequest ? "rectangle.on.rectangle" : "person.fill")
                    .font(.system(size: isRequest ? 22 : 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .background(.regularMaterial, in: Circle())
            }

            // Peer info + status
            VStack(spacing: 4) {
                Text(peer.displayName)
                    .font(.headline)
                Text(isRequest ? "Requesting screen…" : "Calling…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Elapsed timer
            Text(formattedElapsed)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.tertiary)

            // Cancel
            Button {
                callTimer?.invalidate()
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
        .onAppear {
            pulse = true
            startTimer()
        }
        .onDisappear {
            callTimer?.invalidate()
        }
    }

    private var accentColor: Color { isRequest ? .blue : .green }

    private var formattedElapsed: String {
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsed += 1
        }
    }
}
