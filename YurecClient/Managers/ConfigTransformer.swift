import Foundation

/// Transforms a sing-box JSON config for SOCKS5-only mode:
///   - Removes any `tun` inbounds (no root needed)
///   - Removes existing `socks` inbounds and adds a fresh one on the given port
///   - Strips `fakeip` DNS entries (TUN-only feature)
///   - Writes the result to a temp file and returns its URL
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

        // --- Inbounds ---
        var inbounds = (config["inbounds"] as? [[String: Any]]) ?? []
        inbounds.removeAll { ($0["type"] as? String) == "tun"   }
        inbounds.removeAll { ($0["type"] as? String) == "socks" }
        inbounds.insert([
            "type":        "socks",
            "tag":         "socks-in",
            "listen":      "127.0.0.1",
            "listen_port": port
        ], at: 0)
        config["inbounds"] = inbounds

        // --- DNS: strip fakeip (only works with TUN) ---
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

        // --- Route: prepend process_name rule for app routing ---
        // Selected apps get an explicit rule at the top of the rule list that
        // routes them to whatever the profile's `route.final` outbound is.
        // This guarantees those apps go through the proxy even if another rule
        // below would otherwise send them elsewhere.
        //
        // We deliberately do NOT change `route.final` here. Keeping the original
        // final means any app that reaches the SOCKS inbound but is not in the
        // process_name list still follows the profile's default routing — typically
        // "proxy" — so existing per-app proxy settings (e.g. Telegram configured
        // to use 127.0.0.1:2080) continue to work without being listed explicitly.
        //
        // `find_process = true` is required for sing-box to resolve the originating
        // process name of each incoming SOCKS connection.
        if !routedProcessNames.isEmpty {
            var route = (config["route"] as? [String: Any]) ?? [:]
            let proxyOutbound = route["final"] as? String ?? "proxy"
            var rules = (route["rules"] as? [[String: Any]]) ?? []
            rules.insert([
                "process_name": routedProcessNames,
                "outbound": proxyOutbound
            ], at: 0)
            route["rules"] = rules
            route["find_process"] = true
            // route["final"] is intentionally left unchanged — see comment above.
            config["route"] = route
        }

        // Write to temp file (deleted on stop)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("yurec-socks5-\(UUID().uuidString).json")
        let outData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: out)
        return out
    }
}
