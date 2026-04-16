import Foundation
import AppKit

/// A single application entry for SOCKS5 process-name based routing.
///
/// All metadata is extracted from the app bundle at selection time.
/// `appPath` is persisted so the entry survives across sessions even if the app
/// is closed; the icon is always re-fetched from the live filesystem at render time.
struct AppRoutingEntry: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    /// Human-readable name shown in the UI  (e.g. "Telegram").
    let displayName: String
    /// Executable basename — the value sing-box matches in `process_name` routing rules.
    let processName: String
    /// Bundle identifier when available (e.g. "ph.telegra.Telegraph").
    let bundleIdentifier: String?
    /// Absolute path to the .app bundle, used for icon lookup.
    let appPath: String

    // MARK: - Initialisers

    /// Initialise from a `.app` bundle URL.
    init(appURL: URL) {
        id = UUID()
        appPath = appURL.path

        let bundle = Bundle(url: appURL)
        bundleIdentifier = bundle?.bundleIdentifier

        // Prefer CFBundleDisplayName → CFBundleName → filename (without .app)
        displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        // Executable basename is what sing-box's process_name rule matches against
        processName = bundle?.executableURL?.lastPathComponent
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    /// Initialise from a plain executable URL (not a `.app` bundle).
    /// Use this for standalone binaries such as `claude`, `node`, etc.
    init(executableURL: URL) {
        id = UUID()
        appPath = executableURL.path
        bundleIdentifier = nil
        displayName = executableURL.lastPathComponent
        processName = executableURL.lastPathComponent
    }

    // MARK: - Process name resolution

    /// All process names that should be included in the sing-box `process_name` routing rule.
    ///
    /// On macOS, apps spawn various sub-processes with different names:
    ///   • Electron helper processes (`Claude Helper (Renderer)`, `Code Helper (Plugin)`, …)
    ///   • Auto-updater processes (`Updater` inside Sparkle.framework)
    ///   • XPC services (`Downloader`, `Installer` for Sparkle updates)
    ///   • App extensions (`.appex`)
    ///
    /// We enumerate all `.app`, `.xpc`, and `.appex` bundles recursively inside the
    /// main app's `Contents/` directory. When a sub-bundle is found we call
    /// `skipDescendants()` so we don't descend into *its* internals — only bundles
    /// that are direct sub-components of the top-level app are collected.
    ///
    /// Computed live from the bundle — no storage or migration needed.
    var allProcessNames: [String] {
        var names: [String] = [processName]
        let contentsDir = URL(fileURLWithPath: appPath).appendingPathComponent("Contents")
        guard let enumerator = FileManager.default.enumerator(
            at: contentsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return names }

        let bundleExtensions: Set<String> = ["app", "xpc", "appex"]
        for case let url as URL in enumerator {
            guard bundleExtensions.contains(url.pathExtension) else { continue }
            // Don't descend into this sub-bundle's own internals.
            enumerator.skipDescendants()
            if let name = Bundle(url: url)?.executableURL?.lastPathComponent,
               !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - UI helpers

    /// Returns the app's Finder icon, scaled for inline list display.
    /// Not persisted — always resolved live so it stays in sync with the OS theme.
    func icon(size: CGFloat = 20) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: size, height: size)
        return image
    }
}
