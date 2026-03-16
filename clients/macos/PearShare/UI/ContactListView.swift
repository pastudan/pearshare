import SwiftUI

@MainActor
protocol ContactListViewDelegate: AnyObject {
    /// Caller shares their screen to the peer (caller = host, peer = viewer).
    func ring(peer: PearPeer)
    /// Caller asks the peer to share their screen (caller = viewer, peer = host).
    func requestScreen(from peer: PearPeer)
    /// Called when the user confirms trust through TrustApprovalView.
    func grantTrust(to peer: PearPeer)
}

struct ContactListView: View {
    @ObservedObject var peerStore: PeerStore
    weak var delegate: ContactListViewDelegate?

    @State private var showingExcludedApps = false
    @State private var showingTrustedDevices = false
    @State private var trustApprovalPeer: PearPeer? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            peerList
            Divider()
            footer
        }
        .frame(width: 300, height: 400)
        .background(.regularMaterial)
        .sheet(isPresented: $showingExcludedApps) {
            ExcludedAppsView(store: ExcludedAppsStore.shared)
        }
        .sheet(isPresented: $showingTrustedDevices) {
            TrustedDevicesView()
        }
        .sheet(item: $trustApprovalPeer) { peer in
            TrustApprovalView(peer: peer) {
                delegate?.grantTrust(to: peer)
                trustApprovalPeer = nil
            } onCancelled: {
                trustApprovalPeer = nil
            }
        }
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                showingExcludedApps = true
            } label: {
                Image(systemName: "eye.slash").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hidden apps")

            Button {
                showingTrustedDevices = true
            } label: {
                Image(systemName: "lock.shield").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Trusted Devices")

            Spacer()
            Button("Quit PearShare") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Peer list

    @ViewBuilder
    private var peerList: some View {
        if peerStore.peers.isEmpty {
            emptyState
        } else {
            List(peerStore.peers) { peer in
                PeerRowView(
                    peer: peer,
                    isTrusted: TrustedDeviceStore.shared.isTrusted(peerID: peer.id),
                    onShare: { delegate?.ring(peer: peer) },
                    onRequest: { delegate?.requestScreen(from: peer) },
                    onAlwaysAllow: { trustApprovalPeer = peer }
                )
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
    let isTrusted: Bool
    let onShare: () -> Void
    let onRequest: () -> Void
    let onAlwaysAllow: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Name + platform
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(peer.displayName)
                        .font(.subheadline.weight(.medium))
                    if isTrusted {
                        Text("Auto-answers")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("When this device calls you, your Mac will auto-answer and share your screen — no prompt")
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: platformIcon)
                        .font(.caption2)
                    Text(peer.hostName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Actions — appear on hover
            if isHovered && peer.status != .busy {
                HStack(spacing: 8) {
                    // Secondary: Request (text link style)
                    Button(action: onRequest) {
                        Text("Request")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help("Ask \(peer.displayName) to share their screen with you")

                    // Primary: Share (icon button)
                    Button(action: onShare) {
                        Image(systemName: "rectangle.on.rectangle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.green)
                    .transition(.opacity.combined(with: .scale))
                    .help("Share your screen with \(peer.displayName)")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button {
                onShare()
            } label: {
                Label("Share My Screen", systemImage: "rectangle.on.rectangle.fill")
            }
            .disabled(peer.status == .busy)

            Button {
                onRequest()
            } label: {
                Label("Request Their Screen", systemImage: "rectangle.on.rectangle")
            }
            .disabled(peer.status == .busy)

            Divider()

            if isTrusted {
                Button {
                    onAlwaysAllow()
                } label: {
                    Label("Manage Trust...", systemImage: "lock.shield")
                }
            } else {
                Button {
                    onAlwaysAllow()
                } label: {
                    Label("Always Allow (Auto-answer for this device)", systemImage: "lock.open")
                }
                .disabled(peer.publicKey == nil || peer.publicKey?.isEmpty == true)
                .help(peer.publicKey == nil ? "Peer must be running a compatible PearShare to add" : "When this device calls you, you'll auto-answer and share your screen")
            }
        }
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
