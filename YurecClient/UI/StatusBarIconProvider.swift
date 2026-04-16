import AppKit

/// Maps VPN connection states to native SF Symbol template images.
///
/// Symbol mapping:
///   off    → "power"                     — neutral; signals inactive
///   tunnel → "lock.fill"                 — solid lock = full system protection
///   socks  → "arrow.triangle.branch"     — branching/routing = selective proxy
///   error  → "exclamationmark.triangle.fill" — standard macOS warning
///
/// All images carry `isTemplate = true` so macOS applies the correct tint
/// automatically across light mode, dark mode, tinted bar, and high contrast.
/// No custom colors or compositing — the system handles everything.
enum StatusBarIconProvider {

    private static let symbolConfig = NSImage.SymbolConfiguration(
        pointSize: 13, weight: .medium
    )

    // MARK: - Public

    static func image(for state: StatusBarIconState) -> NSImage {
        let name = symbolName(for: state)
        guard
            let base = NSImage(systemSymbolName: name,
                               accessibilityDescription: state.accessibilityDescription),
            let img  = base.withSymbolConfiguration(symbolConfig)
        else {
            return NSImage()
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Symbol mapping

    private static func symbolName(for state: StatusBarIconState) -> String {
        switch state {
        case .off:
            return "power"
        case .tunnel, .connectingTunnel:
            // lock.fill — strong, unambiguous "protected" silhouette
            return "lock.fill"
        case .socks, .connectingSocks:
            // arrow.triangle.branch — visual metaphor for selective routing / proxy
            return "arrow.triangle.branch"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
