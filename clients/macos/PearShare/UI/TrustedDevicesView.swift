import SwiftUI

// MARK: - TrustedDevicesView
//
// Shows all devices this machine has granted permanent auto-answer access to.
// Each row has a Revoke button — revoking is local-only; the next ring from
// that device will simply fall through to the normal incoming call UI.

struct TrustedDevicesView: View {

    @State private var devices: [TrustedDevice] = []
    @State private var revokeTarget: TrustedDevice?
    @State private var showingRevokeConfirm = false
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trusted Devices")
                        .font(.headline)
                    Text("These devices can connect to your screen without asking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(16)

            Divider()

            if devices.isEmpty {
                emptyState
            } else {
                deviceList
            }

            Divider()

            // Footer warning
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Revoke access at any time to require manual approval again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 380, height: devices.isEmpty ? 260 : min(80 + CGFloat(devices.count) * 72, 500))
        .onAppear { devices = TrustedDeviceStore.shared.all }
        .confirmationDialog(
            "Revoke access for \"\(revokeTarget?.displayName ?? "")\"?",
            isPresented: $showingRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("Revoke Access", role: .destructive) {
                if let target = revokeTarget {
                    TrustedDeviceStore.shared.revoke(peerID: target.peerID)
                    devices = TrustedDeviceStore.shared.all
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(revokeTarget?.displayName ?? "This device") will need to be manually approved for future calls.")
        }
    }

    // MARK: - Device list

    private var deviceList: some View {
        List(devices) { device in
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lock.open.fill")
                        .font(.body)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("Trusted \(Self.dateFormatter.string(from: device.grantedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.peerID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Revoke") {
                    revokeTarget = device
                    showingRevokeConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No trusted devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Right-click a contact and choose \"Always Allow\" to give them permanent access to this Mac's screen.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
