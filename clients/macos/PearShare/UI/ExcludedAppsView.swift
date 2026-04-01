import SwiftUI
import AppKit

/// Settings sheet: manage which apps are blacked-out during screen capture.
struct ExcludedAppsView: View {
    @ObservedObject var store: ExcludedAppsStore
    @Environment(\.dismiss) private var dismiss

    @State private var newBundleID = ""
    @State private var showingPicker = false

    // Split catalogue entries by whether the app is installed on this Mac
    private var installedCategories: [(AppCategory, [AppEntry])] {
        ExcludedAppsStore.catalogue.compactMap { cat in
            let installed = cat.entries.filter(\.isInstalled)
            return installed.isEmpty ? nil : (cat, installed)
        }
    }

    private var notInstalledCategories: [(AppCategory, [AppEntry])] {
        ExcludedAppsStore.catalogue.compactMap { cat in
            let missing = cat.entries.filter { !$0.isInstalled }
            return missing.isEmpty ? nil : (cat, missing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    installedSection
                    notInstalledSection
                    customSection
                }
            }
            Divider()
            addRow
        }
        .frame(width: 420, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(.secondary)
                Text("Hidden from Screen Capture")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
            }
            Text("Windows from these apps appear black to the remote viewer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Installed apps section

    @ViewBuilder
    private var installedSection: some View {
        if !installedCategories.isEmpty {
            SectionHeader(title: "On This Mac", systemImage: "checkmark.circle.fill", tint: .green)
            ForEach(installedCategories, id: \.0.id) { cat, entries in
                CategoryBlock(store: store, category: cat, entries: entries, dimmed: false)
            }
        }
    }

    // MARK: - Not-installed section

    @ViewBuilder
    private var notInstalledSection: some View {
        if !notInstalledCategories.isEmpty {
            SectionHeader(title: "Will Be Hidden If Installed", systemImage: "clock", tint: .secondary)
            ForEach(notInstalledCategories, id: \.0.id) { cat, entries in
                CategoryBlock(store: store, category: cat, entries: entries, dimmed: true)
            }
        }
    }

    // MARK: - Custom apps section

    @ViewBuilder
    private var customSection: some View {
        if !store.customEntries.isEmpty {
            SectionHeader(title: "Added by You", systemImage: "person.fill", tint: .blue)
            ForEach(store.customEntries) { entry in
                AppToggleRow(store: store, entry: entry, dimmed: !entry.isInstalled) {
                    store.removeCustom(entry)
                }
                Divider().padding(.leading, 44)
            }
        }
    }

    // MARK: - Add row

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Add bundle ID (e.g. com.example.App)", text: $newBundleID)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onSubmit { commitAdd() }

            Button("Add") { commitAdd() }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                showingPicker = true
            } label: {
                Image(systemName: "folder")
            }
            .help("Choose an application")
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.application],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importApp(from: url)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func commitAdd() {
        let id = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        store.addCustom(bundleID: id)
        newBundleID = ""
    }
}

// MARK: - SectionHeader

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - CategoryBlock

/// A collapsible group for one category with a header toggle.
private struct CategoryBlock: View {
    @ObservedObject var store: ExcludedAppsStore
    let category: AppCategory
    let entries: [AppEntry]
    let dimmed: Bool

    @State private var isExpanded = true

    private var categoryEnabled: Bool {
        store.isEnabled(category: category)
    }

    // True only if the category has a mix of on/off entries (shows indeterminate state)
    private var isMixed: Bool {
        let states = entries.map { store.enabledMap[$0.id] ?? true }
        return states.contains(true) && states.contains(false)
    }

    var body: some View {
        // Category header row
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)

                Text(category.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(dimmed ? .secondary : .primary)

                Spacer()

                // Category-level toggle: turns all entries in this category on/off
                Toggle("", isOn: Binding(
                    get: { categoryEnabled },
                    set: { store.setEnabled($0, for: category) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .opacity(isMixed ? 0.6 : 1)  // hint that it's mixed
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.03))

        if isExpanded {
            ForEach(entries) { entry in
                AppToggleRow(store: store, entry: entry, dimmed: dimmed, onRemove: nil)
                    .padding(.leading, 20)
                Divider().padding(.leading, 64)
            }
        }
    }
}

// MARK: - AppToggleRow

private struct AppToggleRow: View {
    @ObservedObject var store: ExcludedAppsStore
    let entry: AppEntry
    let dimmed: Bool
    let onRemove: (() -> Void)?

    @State private var isHovered = false

    private var isEnabled: Bool {
        store.enabledMap[entry.id] ?? true
    }

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.tertiary)
                }
            }

            // Name + bundle ID
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                Text(entry.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Remove button for custom entries (appears on hover)
            if let onRemove, isHovered {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove from hidden apps")
                .transition(.opacity)
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { store.setEnabled($0, for: entry.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
