import SwiftUI

struct IncomingRingView: View {
    let peer: PearPeer
    let onResponse: (Bool) -> Void

    @State private var timeRemaining: Int = 30
    @State private var ringTimer: Timer?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            // Pulsing avatar ring
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(pulse ? 0.2 : 0.5), lineWidth: pulse ? 16 : 4)
                    .frame(width: 64, height: 64)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: "person.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .background(.regularMaterial, in: Circle())
            }

            // Caller info
            VStack(spacing: 4) {
                Text(peer.displayName)
                    .font(.headline)
                Text("Incoming PearShare from \(peer.hostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Countdown
            Text("Auto-declining in \(timeRemaining)s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            // Buttons
            HStack(spacing: 20) {
                Button {
                    ringTimer?.invalidate()
                    onResponse(false)
                } label: {
                    Label("Decline", systemImage: "phone.down.fill")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

                Button {
                    ringTimer?.invalidate()
                    onResponse(true)
                } label: {
                    Label("Accept", systemImage: "phone.fill")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
        .onAppear {
            pulse = true
            startCountdown()
        }
        .onDisappear {
            ringTimer?.invalidate()
        }
    }

    private func startCountdown() {
        ringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            timeRemaining -= 1
            if timeRemaining <= 0 {
                ringTimer?.invalidate()
                onResponse(false)
            }
        }
    }
}
