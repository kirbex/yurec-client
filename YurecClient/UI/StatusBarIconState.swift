import Foundation

/// Visual state of the status-bar icon.
///
/// Intentionally separate from ``ConnectionMode`` (business logic) so the icon
/// system can evolve independently — e.g. add "error" or "connecting" states
/// without touching ProxyManager.
enum StatusBarIconState: Equatable {
    /// No active connection.
    case off
    /// Connecting in tunnel mode (transient, shows pulse animation).
    case connectingTunnel
    /// Connecting in SOCKS5 mode (transient, shows pulse animation).
    case connectingSocks
    /// Full tunnel (TUN) is active.
    case tunnel
    /// Local SOCKS5 proxy is active.
    case socks
    /// sing-box exited unexpectedly.
    case error

    // MARK: - Initialiser

    /// Derives the visual state from ProxyManager's published properties.
    /// Pass `isConnecting: true` while start() is in-flight to show the
    /// connecting animation.
    init(isRunning: Bool,
         isConnecting: Bool = false,
         mode: ConnectionMode?,
         hasError: Bool = false) {
        if hasError {
            self = .error
            return
        }
        if isConnecting {
            self = (mode == .tun) ? .connectingTunnel : .connectingSocks
            return
        }
        guard isRunning, let mode else {
            self = .off
            return
        }
        switch mode {
        case .tun:    self = .tunnel
        case .socks5: self = .socks
        }
    }

    /// Human-readable description used in accessibility labels.
    var accessibilityDescription: String {
        switch self {
        case .off:               return "VPN off"
        case .connectingTunnel:  return "Connecting tunnel…"
        case .connectingSocks:   return "Connecting SOCKS5…"
        case .tunnel:            return "Tunnel active"
        case .socks:             return "SOCKS5 active"
        case .error:             return "VPN error"
        }
    }

    var isConnecting: Bool {
        self == .connectingTunnel || self == .connectingSocks
    }
}
