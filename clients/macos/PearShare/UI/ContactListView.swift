import SwiftUI

@MainActor
protocol ContactListViewDelegate: AnyObject {
    func ring(peer: PearPeer)
}

struct ContactListView: View {
    @ObservedObject var peerStore: PeerStore
    weak var delegate: ContactListViewDelegate?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            peerList
        }
        .frame(width: 300, height: 400)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "circle.fill")
                .foregroundStyle(peerStore.tailscaleOnline ? .green : .red)
                .font(.caption)
            Text(peerStore.tailscaleOnline ? "Tailscale connected" : "Tailscale offline")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(peerStore.selfHostName)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Peer list

    @ViewBuilder
    private var peerList: some View {
        if peerStore.peers.isEmpty {
            emptyState
        } else {
            List(peerStore.peers) { peer in
                PeerRowView(peer: peer) {
                    delegate?.ring(peer: peer)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No PearShare peers online")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Peers appear automatically when they're online and running PearShare.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PeerRowView

struct PeerRowView: View {
    let peer: PearPeer
    let onRing: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Name + platform
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Image(systemName: platformIcon)
                        .font(.caption2)
                    Text(peer.hostName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Ring button — appears on hover
            if isHovered && peer.status != .busy {
                Button(action: onRing) {
                    Image(systemName: "phone.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.green)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var statusColor: Color {
        switch peer.status {
        case .available: return .green
        case .busy:      return .orange
        case .dnd:       return .red
        }
    }

    private var platformIcon: String {
        switch peer.platform {
        case "macos":   return "laptopcomputer"
        case "windows": return "pc"
        default:        return "desktopcomputer"
        }
    }
}
