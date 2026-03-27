import SwiftUI
import AppKit

// MARK: - TrustApprovalView

struct TrustApprovalView: View {

    let peer: PearPeer
    /// Called when the user confirms trust.
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
                    dismiss()
                    onConfirmed()
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
