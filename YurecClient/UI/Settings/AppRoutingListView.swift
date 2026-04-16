import SwiftUI
import AppKit

/// Reusable list component for displaying and editing a collection of `AppRoutingEntry` items.
/// Used in both the global settings section and per-profile override sections.
///
/// The view is intentionally read-only with respect to its data — mutations go through
/// `onAdd` / `onRemove` callbacks so the caller controls the source of truth.
struct AppRoutingListView: View {
    let entries: [AppRoutingEntry]
    /// Called when the user taps "+"; the caller should open a picker and add entries.
    let onAdd: () -> Void
    /// Called with the ID of the entry the user wants to remove.
    let onRemove: (UUID) -> Void

    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            listBody
            controlBar
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var listBody: some View {
        if entries.isEmpty {
            HStack {
                Spacer()
                Text("No apps selected")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(minHeight: 56)
        } else {
            List(entries, selection: $selectedID) { entry in
                AppRoutingRowView(entry: entry)
                    .tag(entry.id)
            }
            .listStyle(.plain)
            .frame(minHeight: 56)
        }
    }

    private var controlBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Add application")

                Divider().frame(height: 14)

                Button {
                    guard let id = selectedID else { return }
                    onRemove(id)
                    selectedID = nil
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                .help("Remove selected application")

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Row

private struct AppRoutingRowView: View {
    let entry: AppRoutingEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: entry.icon(size: 20))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.body)
                // Show the process name only when it differs from the display name —
                // it's the technical identifier sing-box uses, useful for power users.
                if entry.processName != entry.displayName {
                    Text(entry.processName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - App picker helper

/// Opens an NSOpenPanel for picking `.app` bundles or plain executables and returns
/// `AppRoutingEntry` values for each selection. Duplicate process names
/// (compared to `existing`) are silently filtered out.
func pickAppsForRouting(existing: [AppRoutingEntry]) -> [AppRoutingEntry] {
    let panel = NSOpenPanel()
    panel.title = "Select Applications or Executables to Route via VPN"
    panel.prompt = "Add"
    panel.message = "Choose .app bundles or plain executables (e.g. /usr/local/bin/claude)"
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false   // show .app as single item, not navigable
    panel.directoryURL = URL(fileURLWithPath: "/Applications")

    guard panel.runModal() == .OK else { return [] }

    let existingNames = Set(existing.flatMap(\.allProcessNames))
    return panel.urls.compactMap { url -> AppRoutingEntry? in
        let entry = url.pathExtension == "app"
            ? AppRoutingEntry(appURL: url)
            : AppRoutingEntry(executableURL: url)
        // Skip if the main process name is already covered
        return existingNames.contains(entry.processName) ? nil : entry
    }
}
