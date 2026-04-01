import SwiftUI

struct IncomingRingView: View {
    let peer: PearPeer
    /// "share" = they are sharing their screen to us (we watch).
    /// "request" = they want us to share our screen to them.
    let intent: String
    let onResponse: (Bool) -> Void

    @State private var timeRemaining: Int = 30
    @State private var ringTimer: Timer?
    @State private var pulse = false

    private var isRequest: Bool { intent == "request" }

    var body: some View {
        VStack(spacing: 16) {
            // Pulsing avatar ring — green for share, blue for request
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(pulse ? 0.2 : 0.5), lineWidth: pulse ? 16 : 4)
                    .frame(width: 64, height: 64)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: isRequest ? "rectangle.on.rectangle" : "person.fill")
                    .font(.system(size: isRequest ? 22 : 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .background(.regularMaterial, in: Circle())
            }

            // Caller info
            VStack(spacing: 4) {
                Text(peer.displayName)
                    .font(.headline)
                Text(isRequest
                     ? "\(peer.hostName) wants to view your screen"
                     : "Incoming screen share from \(peer.hostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // For requests: a prominent banner explaining what accepting means
            if isRequest {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                        .font(.footnote)
                    Text("Accepting will share your entire screen. You can optionally grant keyboard & mouse control from the session banner.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.25), lineWidth: 1))
                .foregroundStyle(Color.blue)
            }

            // Countdown
            Text("Auto-declining in \(timeRemaining)s")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            // Buttons
            HStack(spacing: 12) {
                Button {
                    ringTimer?.invalidate()
                    onResponse(false)
                } label: {
                    Label("Decline", systemImage: "xmark")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

                if isRequest {
                    // Distinct "Share My Screen" accept button
                    Button {
                        ringTimer?.invalidate()
                        onResponse(true)
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.on.rectangle.fill")
                                Text("Share My Screen")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.large)
                } else {
                    Button {
                        ringTimer?.invalidate()
                        onResponse(true)
                    } label: {
                        Label("Accept", systemImage: "phone.fill")
                            .frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(width: isRequest ? 360 : 300)
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

    private var accentColor: Color {
        isRequest ? .blue : .green
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
