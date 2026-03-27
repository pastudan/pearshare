import SwiftUI
import AppKit

extension Color {
    static let pearGreen = Color(red: 0.18, green: 0.95, blue: 0.45)
}

extension NSColor {
    static let pearGreen = NSColor(red: 0.18, green: 0.95, blue: 0.45, alpha: 1.0)
}

// MARK: - PearSettings keys

enum PearSettings {
    /// UserDefaults key: automatically accept incoming "share" rings without prompting.
    static let autoAcceptSharesKey = "autoAcceptIncomingShares"
}

// MARK: - SessionStateStore

/// Observable session state shared between AppDelegate and the menu-bar popover.
/// AppDelegate updates this when sessions start / end so the ContactListView
/// can reactively reflect the active call without polling.
@MainActor
final class SessionStateStore: ObservableObject {
    @Published var activePeer: PearPeer? = nil
    @Published var role: SessionRole? = nil

    var isInSession: Bool { activePeer != nil }
}
