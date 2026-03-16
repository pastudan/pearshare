import Foundation
import AppKit
import Combine

// MARK: - Model

struct AppEntry: Identifiable, Equatable {
    let id: String          // bundle ID
    let displayName: String // human-readable label shown in UI

    /// Whether this app is currently installed on the machine.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// App icon if installed, nil otherwise.
    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct AppCategory: Identifiable {
    let id: String      // stable key used for UserDefaults
    let name: String
    let entries: [AppEntry]
}

// MARK: - Store

/// Manages which apps are blacked-out during screen capture.
/// Persists per-bundle-ID enabled/disabled state in UserDefaults.
final class ExcludedAppsStore: ObservableObject {

    static let shared = ExcludedAppsStore()

    // MARK: Catalogue

    /// All known categories and their apps. Adding entries here auto-enables them on first launch.
    static let catalogue: [AppCategory] = [
        AppCategory(id: "passwords", name: "Password Managers", entries: [
            AppEntry(id: "com.agilebits.onepassword-osx",      displayName: "1Password"),
            AppEntry(id: "com.agilebits.onepassword7",          displayName: "1Password 7"),
            AppEntry(id: "com.markmcguill.strongbox",           displayName: "Strongbox"),
            AppEntry(id: "org.keepassxc.keepassxc",             displayName: "KeePassXC"),
            AppEntry(id: "com.bitwarden.desktop",               displayName: "Bitwarden"),
            AppEntry(id: "com.lastpass.lastpassmacdesktop",     displayName: "LastPass"),
            AppEntry(id: "com.dashlane.dashlane-mac",           displayName: "Dashlane"),
            AppEntry(id: "com.apple.Passwords",                 displayName: "Passwords"),
        ]),
        AppCategory(id: "notes", name: "Notes & Journals", entries: [
            AppEntry(id: "com.apple.Notes",     displayName: "Notes"),
            AppEntry(id: "md.obsidian",          displayName: "Obsidian"),
            AppEntry(id: "com.notion.id",        displayName: "Notion"),
            AppEntry(id: "com.evernote.Evernote",displayName: "Evernote"),
            AppEntry(id: "com.bear.app",         displayName: "Bear"),
        ]),
        AppCategory(id: "communication", name: "Messages & Email", entries: [
            AppEntry(id: "com.apple.MobileSMS",         displayName: "Messages"),
            AppEntry(id: "com.apple.mail",               displayName: "Mail"),
            AppEntry(id: "com.tinyspeck.slackmacgap",    displayName: "Slack"),
            AppEntry(id: "com.microsoft.teams2",         displayName: "Microsoft Teams"),
            AppEntry(id: "com.hnc.Discord",              displayName: "Discord"),
            AppEntry(id: "ru.keepcoder.Telegram",        displayName: "Telegram"),
            AppEntry(id: "com.whatsapp.WhatsApp",        displayName: "WhatsApp"),
            AppEntry(id: "com.microsoft.Outlook",        displayName: "Outlook"),
        ]),
        AppCategory(id: "finance", name: "Banking & Finance", entries: [
            AppEntry(id: "com.mint.Mint",               displayName: "Mint"),
            AppEntry(id: "com.robinhood.production",     displayName: "Robinhood"),
            AppEntry(id: "com.coinbase.CoinbasePro",     displayName: "Coinbase"),
            AppEntry(id: "com.paypal.PayPal",            displayName: "PayPal"),
        ]),
        AppCategory(id: "auth", name: "Authentication", entries: [
            AppEntry(id: "com.authy.authy-mac",          displayName: "Authy"),
            AppEntry(id: "com.microsoft.Authenticator",  displayName: "Microsoft Authenticator"),
        ]),
        AppCategory(id: "system", name: "System & Health", entries: [
            AppEntry(id: "com.apple.Passbook",           displayName: "Wallet"),
            AppEntry(id: "com.apple.healthdata",         displayName: "Health"),
            AppEntry(id: "com.apple.iCal",               displayName: "Calendar"),
        ]),
    ]

    // MARK: State

    /// Maps bundle ID → enabled. Persisted to UserDefaults.
    /// Entries not present default to `true` (new catalogue entries are on by default).
    @Published private(set) var enabledMap: [String: Bool] {
        didSet { UserDefaults.standard.set(enabledMap, forKey: udKey) }
    }

    /// Custom entries added by the user (bundle ID → display name).
    @Published private(set) var customEntries: [AppEntry] {
        didSet {
            let encoded = customEntries.map { ["id": $0.id, "name": $0.displayName] }
            UserDefaults.standard.set(encoded, forKey: customKey)
        }
    }

    private let udKey = "PearShare.excludedBundleIDs.v2"
    private let customKey = "PearShare.excludedBundleIDs.custom"

    /// The flat list of enabled bundle IDs passed to ScreenCaptureKit.
    var enabledBundleIDs: [String] {
        let catalogueIDs = ExcludedAppsStore.catalogue
            .flatMap(\.entries)
            .filter { enabledMap[$0.id] ?? true }
            .map(\.id)
        let customIDs = customEntries
            .filter { enabledMap[$0.id] ?? true }
            .map(\.id)
        return catalogueIDs + customIDs
    }

    private init() {
        // Load persisted enabled map
        if let saved = UserDefaults.standard.dictionary(forKey: "PearShare.excludedBundleIDs.v2") as? [String: Bool] {
            enabledMap = saved
        } else {
            enabledMap = [:]  // all catalogue entries default to enabled
        }

        // Load custom entries
        if let raw = UserDefaults.standard.array(forKey: "PearShare.excludedBundleIDs.custom") as? [[String: String]] {
            customEntries = raw.compactMap { dict in
                guard let id = dict["id"], let name = dict["name"] else { return nil }
                return AppEntry(id: id, displayName: name)
            }
        } else {
            customEntries = []
        }
    }

    // MARK: - Mutations

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        enabledMap[bundleID] = enabled
    }

    /// Returns true if every entry in the category is enabled.
    func isEnabled(category: AppCategory) -> Bool {
        category.entries.allSatisfy { enabledMap[$0.id] ?? true }
    }

    /// Toggles all entries in a category on or off.
    func setEnabled(_ enabled: Bool, for category: AppCategory) {
        for entry in category.entries {
            enabledMap[entry.id] = enabled
        }
    }

    func addCustom(bundleID: String, displayName: String? = nil) {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        // Don't add duplicates across catalogue or custom list
        let allKnown = ExcludedAppsStore.catalogue.flatMap(\.entries).map(\.id) + customEntries.map(\.id)
        guard !allKnown.contains(id) else { return }

        let name: String
        if let provided = displayName, !provided.isEmpty {
            name = provided
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = id
        }
        customEntries.append(AppEntry(id: id, displayName: name))
        enabledMap[id] = true
    }

    func removeCustom(_ entry: AppEntry) {
        customEntries.removeAll { $0.id == entry.id }
        enabledMap.removeValue(forKey: entry.id)
    }

    /// Read bundle ID from a .app bundle URL chosen by the user.
    func importApp(from url: URL) {
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoPlist),
              let id = dict["CFBundleIdentifier"] as? String else { return }
        let name = url.deletingPathExtension().lastPathComponent
        addCustom(bundleID: id, displayName: name)
    }
}
