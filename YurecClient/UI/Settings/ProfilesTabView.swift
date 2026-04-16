import SwiftUI
import AppKit

struct ProfilesTabView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var routingStore = AppRoutingStore.shared
    @State private var selectedProfileID: UUID?
    @State private var showNewProfileSheet = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var socks5PortText: String = ""
    // Per-profile app routing state
    @State private var profileOverride: Bool = false
    @State private var profileEntries: [AppRoutingEntry] = []

    var selectedProfile: Profile? {
        profileManager.profiles.first(where: { $0.id == selectedProfileID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Profile list
            List(profileManager.profiles, selection: $selectedProfileID) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body)
                    Text(profile.path.path).font(.caption).foregroundColor(.secondary)
                }
                .tag(profile.id)
            }
            .frame(minHeight: 120)
            .border(Color(NSColor.separatorColor))
            .onChange(of: selectedProfileID) { _ in loadSettingsForSelected() }

            // Per-profile settings
            if let profile = selectedProfile {
                Divider()
                profileSettings(for: profile)
            }

            // Bottom toolbar
            HStack(spacing: 8) {
                Button("Add...") { pickFile() }
                Button("Remove") { removeSelected() }.disabled(selectedProfileID == nil)
                Button("Open in Editor") { openSelected() }.disabled(selectedProfileID == nil)
                Spacer()
                Button("New Profile...") { showNewProfileSheet = true }
            }
        }
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileSheet(isPresented: $showNewProfileSheet) { name in
                createProfile(name: name)
            }
        }
        .alert("Error", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { msg in Text(msg) }
    }

    // MARK: - Per-profile settings panel

    @ViewBuilder
    private func profileSettings(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Port
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings for \"\(profile.name)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text("SOCKS5 Port:")
                    TextField("2080", text: $socks5PortText)
                        .frame(width: 70)
                        .onSubmit { savePort() }
                    Text("(used in SOCKS5 mode)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // App routing override section
            appRoutingSection(for: profile)
        }
    }

    @ViewBuilder
    private func appRoutingSection(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header + override toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Routing · SOCKS5")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !profileOverride {
                        Text("Using global defaults")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Toggle("Override global", isOn: $profileOverride)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: profileOverride) { value in
                        routingStore.setOverridesGlobal(value, for: profile)
                        if value && profileEntries.isEmpty {
                            // Seed profile list with current global entries as a starting point
                            profileEntries = routingStore.globalEntries
                            routingStore.setEntries(profileEntries, for: profile)
                        }
                    }
            }

            if profileOverride {
                // Editable profile-specific list
                AppRoutingListView(
                    entries: profileEntries,
                    onAdd: { addProfileApp(for: profile) },
                    onRemove: { id in
                        profileEntries.removeAll { $0.id == id }
                        routingStore.setEntries(profileEntries, for: profile)
                    }
                )
                .frame(minHeight: 80)
            } else {
                // Read-only view of inherited global list
                inheritedGlobalView
            }

            reconnectNoteIfNeeded
        }
        .padding(.bottom, 4)
    }

    // Read-only list showing the global entries the profile inherits
    @ViewBuilder
    private var inheritedGlobalView: some View {
        let globals = routingStore.globalEntries
        if globals.isEmpty {
            Text("No global defaults configured — go to General to add apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(globals) { entry in
                    HStack(spacing: 8) {
                        Image(nsImage: entry.icon(size: 16))
                            .resizable().frame(width: 16, height: 16)
                        Text(entry.displayName).font(.callout)
                        Spacer()
                        Text("inherited")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(NSColor.tertiaryLabelColor).opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    if entry.id != globals.last?.id { Divider() }
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var reconnectNoteIfNeeded: some View {
        let proxy = ProxyManager.shared
        if proxy.isRunning, case .socks5 = proxy.currentMode {
            Label("Changes take effect after reconnecting SOCKS5.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Profile actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try profileManager.addProfile(from: url) }
            catch { present(error) }
        }
    }

    private func removeSelected() {
        guard let profile = selectedProfile else { return }
        do {
            try profileManager.removeProfile(profile)
            selectedProfileID = nil
        } catch { present(error) }
    }

    private func openSelected() {
        guard let profile = selectedProfile else { return }
        profileManager.openInEditor(profile)
    }

    private func createProfile(name: String) {
        do { try profileManager.createNewProfile(name: name) }
        catch { present(error) }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    // MARK: - Settings load/save

    private func loadSettingsForSelected() {
        guard let profile = selectedProfile else {
            socks5PortText = ""
            profileOverride = false
            profileEntries = []
            return
        }
        socks5PortText = "\(profileManager.socks5Port(for: profile))"
        profileOverride = routingStore.overridesGlobal(for: profile)
        profileEntries = routingStore.entries(for: profile)
    }

    private func savePort() {
        guard let profile = selectedProfile,
              let port = Int(socks5PortText), port > 0, port < 65536 else { return }
        profileManager.setSocks5Port(port, for: profile)
    }

    // MARK: - App routing helpers

    private func addProfileApp(for profile: Profile) {
        let new = pickAppsForRouting(existing: profileEntries)
        profileEntries.append(contentsOf: new)
        routingStore.setEntries(profileEntries, for: profile)
    }
}

// MARK: - New Profile Sheet

struct NewProfileSheet: View {
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.headline)
            TextField("Profile name", text: $name).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    isPresented = false
                    onCreate(name)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
