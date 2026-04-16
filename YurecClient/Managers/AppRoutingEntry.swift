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

    // MARK: - Initialisation from a bundle URL

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

    // MARK: - UI helpers

    /// Returns the app's Finder icon, scaled for inline list display.
    /// Not persisted — always resolved live so it stays in sync with the OS theme.
    func icon(size: CGFloat = 20) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: size, height: size)
        return image
    }
}
