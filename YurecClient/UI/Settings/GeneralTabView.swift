import SwiftUI
import AppKit

struct GeneralTabView: View {
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    @ObservedObject private var routingStore = AppRoutingStore.shared
    @State private var autoConnect: Bool = UserDefaults.standard.bool(forKey: "autoConnectOnLaunch")
    @State private var binaryPath: String = UserDefaults.standard.string(forKey: "yurecBinaryPath") ?? ""

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.setEnabled($0) }
                ))

                Toggle("Auto-connect on Launch", isOn: $autoConnect)
                    .onChange(of: autoConnect) { value in
                        UserDefaults.standard.set(value, forKey: "autoConnectOnLaunch")
                    }
            }

            Section("sing-box Binary") {
                HStack {
                    TextField("Path (leave empty for auto-detect)", text: $binaryPath)
                        .onChange(of: binaryPath) { value in
                            ProxyManager.shared.updateBinaryPath(value)
                        }
                    Button("Browse...") { pickBinary() }
                }
                Text("Auto-detect order: UserDefaults → /usr/local/bin/sing-box → /opt/homebrew/bin/sing-box → which")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    AppRoutingListView(
                        entries: routingStore.globalEntries,
                        onAdd: addGlobalApp,
                        onRemove: { routingStore.removeGlobal(id: $0) }
                    )
                    .frame(minHeight: 100)

                    reconnectNoteIfNeeded
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default App Routing · SOCKS5")
                    Text("Apps in this list get an explicit proxy routing rule in SOCKS5 mode. Apps not in the list follow the profile's default routing. Individual profiles can override this list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Actions

    private func addGlobalApp() {
        let new = pickAppsForRouting(existing: routingStore.globalEntries)
        new.forEach { routingStore.addGlobal($0) }
    }

    private func pickBinary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Select sing-box binary"
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path
            ProxyManager.shared.updateBinaryPath(url.path)
        }
    }

    // MARK: - Reconnect note

    @ViewBuilder
    private var reconnectNoteIfNeeded: some View {
        let proxy = ProxyManager.shared
        if proxy.isRunning, case .socks5 = proxy.currentMode {
            Label("Changes take effect after reconnecting SOCKS5.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
