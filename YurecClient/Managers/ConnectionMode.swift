import Foundation

enum ConnectionMode: Equatable {
    case tun
    case socks5(port: Int)

    var displayName: String {
        switch self {
        case .tun:              return "TUN (Full VPN)"
        case .socks5(let p):   return "SOCKS5 (port \(p))"
        }
    }

    var requiresRoot: Bool {
        // Both modes run as root via sudo so that SOCKS5 can bind() over
        // root-owned TIME_WAIT sockets left by the previous TUN session.
        // Without this, non-root bind() fails for up to 60 s after TUN stops.
        return true
    }
}
