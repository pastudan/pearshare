import SwiftUI
import AppKit

// MARK: - TrustApprovalView
//
// Stage 1: A sheet with a prominent red danger banner explaining exactly what trust
//   grants — shown first so the user fully reads it before the hard confirm.
// Stage 2: A blocking NSAlert with alertStyle = .critical and a destructive-worded
//   button — the second gate before anything is actually stored or sent.
//
// Only if BOTH stages are confirmed is onConfirmed() called.

struct TrustApprovalView: View {

    let peer: PearPeer
    /// Called when the user passes both confirmation stages.
    let onConfirmed: () -> Void
    let onCancelled: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Red danger banner
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permanent Access Warning")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Read carefully before continuing")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
            }
            .padding(16)
            .background(Color.red.gradient)

            // Body
            VStack(alignment: .leading, spacing: 20) {

                Text("You are about to allow **\(peer.displayName)** to permanently connect to this Mac without asking you first.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                // Bullet list of consequences
                VStack(alignment: .leading, spacing: 10) {
                    TrustWarningRow(
                        icon: "eye.fill",
                        color: .orange,
                        text: "They can view your screen at any time, without any prompt or notification (other than a small banner)."
                    )
                    TrustWarningRow(
                        icon: "cursorarrow.click.2",
                        color: .orange,
                        text: "They will have full keyboard and mouse control of your Mac."
                    )
                    TrustWarningRow(
                        icon: "lock.open.fill",
                        color: .red,
                        text: "This access is permanent — it does not expire until you explicitly revoke it in Trusted Devices settings."
                    )
                    TrustWarningRow(
                        icon: "exclamationmark.shield.fill",
                        color: .red,
                        text: "Only do this for devices you personally own and control."
                    )
                }
                .padding(14)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )

                Text("You can revoke access at any time from the Trusted Devices list in the contact menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                    onCancelled()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button {
                    // Stage 2: NSAlert for the final hard confirmation
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showFinalConfirmation()
                    }
                } label: {
                    Label("I Understand, Continue", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Stage 2: NSAlert

    private func showFinalConfirmation() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Allow \"\(peer.displayName)\" permanent access?"
        alert.informativeText = """
            \(peer.displayName) (\(peer.hostName)) will be able to connect to your Mac and take full control of your screen at any time, without warning.

            This cannot be undone without manually revoking access from the Trusted Devices list.
            """

        // Destructive button first (becomes the default, highlighted red-ish)
        alert.addButton(withTitle: "Allow Permanent Access")
        alert.addButton(withTitle: "Cancel")

        // Make the allow button explicitly non-default so Return doesn't accidentally confirm
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\r"  // Return = Cancel (safer default)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onConfirmed()
        } else {
            onCancelled()
        }
    }
}

// MARK: - TrustWarningRow

private struct TrustWarningRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
