import Foundation

/// Transforms a sing-box JSON config for SOCKS5 mode.
///
/// **Plain SOCKS5** (no apps selected — `routedProcessNames` is empty):
///   - Removes `tun` inbounds (no TUN needed)
///   - Replaces `socks` inbound with a fresh one on the given port
///   - Strips `fakeip` DNS entries (TUN-only feature)
///   - Routing unchanged — all traffic goes through proxy by default
///
/// **Hybrid TUN+SOCKS5** (apps selected — `routedProcessNames` is non-empty):
///   - Keeps the `tun` inbound so TUN captures all traffic for per-process routing
///   - Replaces `socks` inbound with a fresh one on the given port
///   - Keeps fakeip DNS (required for TUN)
///   - Selected apps → proxy outbound; route.final = "direct" (everything else bypasses VPN)
enum ConfigTransformer {

    enum Error: LocalizedError {
        case unreadable
        case invalidJSON
        var errorDescription: String? {
            switch self {
            case .unreadable:   return "Cannot read profile config file."
            case .invalidJSON:  return "Profile config is not valid JSON."
            }
        }
    }

    static func makeSocks5Config(from profilePath: String, port: Int, routedProcessNames: [String] = []) throws -> URL {
        guard let data = FileManager.default.contents(atPath: profilePath) else {
            throw Error.unreadable
        }
        guard var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidJSON
        }

        let hybridTun = !routedProcessNames.isEmpty

        // --- Inbounds ---
        var inbounds = (config["inbounds"] as? [[String: Any]]) ?? []
        if !hybridTun {
            // Plain SOCKS5: drop TUN inbound, no root-level network capture needed.
            inbounds.removeAll { ($0["type"] as? String) == "tun" }
        }
        // In hybrid TUN mode the TUN inbound is kept as-is from the profile.
        inbounds.removeAll { ($0["type"] as? String) == "socks" }
        inbounds.insert([
            "type":        "socks",
            "tag":         "socks-in",
            "listen":      "127.0.0.1",
            "listen_port": port
        ], at: 0)
        config["inbounds"] = inbounds

        // --- DNS ---
        if !hybridTun {
            // Plain SOCKS5: strip fakeip (TUN-only feature).
            if var dns = config["dns"] as? [String: Any] {
                if var servers = dns["servers"] as? [[String: Any]] {
                    servers.removeAll { ($0["type"] as? String) == "fakeip" }
                    if servers.isEmpty {
                        servers = [["tag": "remote", "address": "tls://1.1.1.1", "detour": "proxy"]]
                    }
                    dns["servers"] = servers
                }
                dns.removeValue(forKey: "fakeip")
                config["dns"] = dns
            }
        }
        // Hybrid TUN mode: keep fakeip DNS unchanged — TUN requires it.

        // --- Route ---
        if hybridTun {
            // Build routing rules for hybrid TUN+SOCKS5 mode.
            // `find_process = true` lets sing-box resolve the originating process name.
            var route = (config["route"] as? [String: Any]) ?? [:]
            let proxyOutbound = route["final"] as? String ?? "proxy"
            var rules = (route["rules"] as? [[String: Any]]) ?? []

            // Rule 1 — selected apps (including their helper processes) via TUN → proxy.
            rules.insert([
                "process_name": routedProcessNames,
                "outbound":     proxyOutbound
            ], at: 0)

            // Rule 0 — traffic arriving on the SOCKS5 inbound always goes to proxy.
            // This preserves the behaviour of apps (e.g. Telegram) that are manually
            // configured to use the local SOCKS5 proxy: they bypass TUN entirely and
            // connect directly to 127.0.0.1:port, so process_name rules never see them.
            // Without this rule they would fall through to route.final = "direct".
            rules.insert([
                "inbound":  ["socks-in"],
                "outbound": proxyOutbound
            ], at: 0)

            route["rules"]        = rules
            route["find_process"] = true
            route["final"]        = "direct"  // unlisted apps bypass VPN
            config["route"] = route
        }
        // Plain SOCKS5: routing unchanged (all traffic through proxy by default).

        // Write to temp file (deleted on stop)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("yurec-socks5-\(UUID().uuidString).json")
        let outData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: out)
        return out
    }
}
