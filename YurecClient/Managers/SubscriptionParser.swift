import Foundation

/// Converts subscription data (base64-encoded proxy URIs or plain-text URI list) into
/// a complete sing-box JSON configuration. Supported schemes: vless, vmess, ss, trojan, hysteria2/hy2.
enum SubscriptionParser {

    enum Error: LocalizedError {
        case empty
        case noValidProxies

        var errorDescription: String? {
            switch self {
            case .empty:          return "The subscription response is empty."
            case .noValidProxies: return "No supported proxy configurations found in the subscription."
            }
        }
    }

    /// Returns a sing-box JSON Data ready to be written to disk.
    /// If `data` is already a valid sing-box config (has "outbounds" or "route" keys), it is returned as-is.
    static func buildSingboxConfig(from data: Data) throws -> Data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["outbounds"] != nil || json["route"] != nil {
            return data
        }

        let text = decodeSubscription(data)
        guard !text.isEmpty else { throw Error.empty }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("://") }

        var proxyOutbounds: [[String: Any]] = []
        var proxyTags: [String] = []
        var usedTags = Set<String>()

        for line in lines {
            if let ob = parseProxyURI(line, usedTags: &usedTags) {
                proxyTags.append(ob["tag"] as! String)
                proxyOutbounds.append(ob)
            }
        }

        guard !proxyTags.isEmpty else { throw Error.noValidProxies }

        let config = assembleConfig(proxyOutbounds: proxyOutbounds, proxyTags: proxyTags)
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Subscription Decoding

    private static func decodeSubscription(_ data: Data) -> String {
        for candidate in [data, urlSafeData(data)] {
            let padded = padBase64Data(candidate)
            if let decoded = Data(base64Encoded: padded),
               let str = String(data: decoded, encoding: .utf8),
               str.contains("://") {
                return str
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func urlSafeData(_ data: Data) -> Data {
        Data(data.map { b in
            switch b {
            case UInt8(ascii: "-"): return UInt8(ascii: "+")
            case UInt8(ascii: "_"): return UInt8(ascii: "/")
            default: return b
            }
        })
    }

    private static func padBase64Data(_ data: Data) -> Data {
        let r = data.count % 4
        guard r > 0 else { return data }
        return data + Data(repeating: UInt8(ascii: "="), count: 4 - r)
    }

    // MARK: - Proxy URI Dispatch

    private static func parseProxyURI(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        if uri.hasPrefix("vless://")     { return parseVless(uri, usedTags: &usedTags) }
        if uri.hasPrefix("vmess://")     { return parseVmess(uri, usedTags: &usedTags) }
        if uri.hasPrefix("ss://")        { return parseShadowsocks(uri, usedTags: &usedTags) }
        if uri.hasPrefix("trojan://")    { return parseTrojan(uri, usedTags: &usedTags) }
        if uri.hasPrefix("hysteria2://") || uri.hasPrefix("hy2://") { return parseHysteria2(uri, usedTags: &usedTags) }
        return nil
    }

    // MARK: - VLESS

    private static func parseVless(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        // Percent-encode fragment if it contains non-ASCII so URLComponents can parse it
        guard let components = URLComponents(string: preEncodeFragment(uri)) else { return nil }
        guard let uuid   = components.user, !uuid.isEmpty,
              let host   = components.host, !host.isEmpty,
              let port   = components.port else { return nil }

        let name   = components.fragment?.removingPercentEncoding ?? host
        let params = queryDict(components)
        let tag    = uniqueTag(name, usedTags: &usedTags)

        var ob: [String: Any] = [
            "type":        "vless",
            "tag":         tag,
            "server":      host,
            "server_port": port,
            "uuid":        uuid
        ]

        if let flow = params["flow"], !flow.isEmpty { ob["flow"] = flow }

        let security = params["security"] ?? "none"
        if security != "none" { ob["tls"] = buildTLS(params: params) }

        if let transport = buildTransport(params: params) { ob["transport"] = transport }

        return ob
    }

    // MARK: - VMess

    private static func parseVmess(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        let b64 = String(uri.dropFirst("vmess://".count))
        guard let data = decodeBase64(b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let server = json["add"] as? String ?? ""
        guard !server.isEmpty else { return nil }

        let portRaw = (json["port"] as? Int) ?? Int(json["port"] as? String ?? "")
        guard let port = portRaw else { return nil }

        let uuid    = json["id"]  as? String ?? ""
        let alterId = (json["aid"] as? Int) ?? Int(json["aid"] as? String ?? "") ?? 0
        let sec     = json["scy"] as? String ?? json["security"] as? String ?? "auto"
        let net     = json["net"] as? String ?? "tcp"
        let tls     = json["tls"] as? String ?? ""
        let name    = json["ps"]  as? String ?? server
        let tag     = uniqueTag(name.isEmpty ? server : name, usedTags: &usedTags)

        var ob: [String: Any] = [
            "type":        "vmess",
            "tag":         tag,
            "server":      server,
            "server_port": port,
            "uuid":        uuid,
            "security":    sec,
            "alter_id":    alterId
        ]

        if tls == "tls" || tls == "xtls" {
            var tlsObj: [String: Any] = ["enabled": true]
            let sni = (json["sni"] as? String ?? json["host"] as? String ?? "")
            if !sni.isEmpty { tlsObj["server_name"] = sni }
            if let fp = json["fp"] as? String, !fp.isEmpty {
                tlsObj["utls"] = ["enabled": true, "fingerprint": fp]
            }
            if let alpn = json["alpn"] as? String, !alpn.isEmpty {
                tlsObj["alpn"] = alpn.components(separatedBy: ",")
            }
            ob["tls"] = tlsObj
        }

        if let transport = buildVmessTransport(json: json, network: net) {
            ob["transport"] = transport
        }

        return ob
    }

    // MARK: - Shadowsocks

    private static func parseShadowsocks(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        let withoutScheme = String(uri.dropFirst("ss://".count))
        let hashParts  = withoutScheme.components(separatedBy: "#")
        let main       = hashParts[0]
        let nameRaw    = hashParts.dropFirst().joined(separator: "#")
        let name       = nameRaw.removingPercentEncoding ?? nameRaw

        // SIP002: base64(method:password)@host:port
        if let atRange = main.range(of: "@", options: .backwards) {
            let userB64  = String(main[main.startIndex..<atRange.lowerBound]).components(separatedBy: "?")[0]
            let hostPart = String(main[atRange.upperBound...]).components(separatedBy: "?")[0]

            if let decoded = decodeBase64String(userB64),
               let colonIdx = decoded.firstIndex(of: ":"),
               let comps = URLComponents(string: "s://\(hostPart)"),
               let host = comps.host, let port = comps.port {
                let method   = String(decoded[decoded.startIndex..<colonIdx])
                let password = String(decoded[decoded.index(after: colonIdx)...])
                let tag      = uniqueTag(name.isEmpty ? host : name, usedTags: &usedTags)
                return ["type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                        "method": method, "password": password]
            }
        }

        // Legacy: base64(method:password@host:port)
        let b64Part = main.components(separatedBy: "?")[0]
        if let decoded = decodeBase64String(b64Part),
           let atRange = decoded.range(of: "@", options: .backwards) {
            let userInfo = String(decoded[decoded.startIndex..<atRange.lowerBound])
            let hostPart = String(decoded[atRange.upperBound...])
            guard let colonIdx = userInfo.firstIndex(of: ":") else { return nil }
            let method   = String(userInfo[userInfo.startIndex..<colonIdx])
            let password = String(userInfo[userInfo.index(after: colonIdx)...])
            let hostComps = hostPart.components(separatedBy: ":")
            guard let port = Int(hostComps.last ?? "") else { return nil }
            let host = hostComps.dropLast().joined(separator: ":")
            let tag  = uniqueTag(name.isEmpty ? host : name, usedTags: &usedTags)
            return ["type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                    "method": method, "password": password]
        }

        return nil
    }

    // MARK: - Trojan

    private static func parseTrojan(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        guard let components = URLComponents(string: preEncodeFragment(uri)) else { return nil }
        guard let password = components.user, !password.isEmpty,
              let host     = components.host, !host.isEmpty,
              let port     = components.port else { return nil }

        let name   = components.fragment?.removingPercentEncoding ?? host
        let params = queryDict(components)
        let tag    = uniqueTag(name, usedTags: &usedTags)

        var ob: [String: Any] = [
            "type":        "trojan",
            "tag":         tag,
            "server":      host,
            "server_port": port,
            "password":    password.removingPercentEncoding ?? password
        ]

        let security = params["security"] ?? "tls"
        if security != "none" { ob["tls"] = buildTLS(params: params) }
        if let transport = buildTransport(params: params) { ob["transport"] = transport }

        return ob
    }

    // MARK: - Hysteria2

    private static func parseHysteria2(_ uri: String, usedTags: inout Set<String>) -> [String: Any]? {
        let normalized = uri.hasPrefix("hy2://")
            ? "hysteria2://" + uri.dropFirst("hy2://".count)
            : uri
        guard let components = URLComponents(string: preEncodeFragment(normalized)) else { return nil }
        guard let host = components.host, !host.isEmpty,
              let port = components.port else { return nil }

        let auth   = components.user ?? ""
        let name   = components.fragment?.removingPercentEncoding ?? host
        let params = queryDict(components)
        let tag    = uniqueTag(name, usedTags: &usedTags)

        var ob: [String: Any] = [
            "type":        "hysteria2",
            "tag":         tag,
            "server":      host,
            "server_port": port,
            "password":    auth.removingPercentEncoding ?? auth
        ]

        var tlsObj: [String: Any] = ["enabled": true]
        if let sni = params["sni"], !sni.isEmpty { tlsObj["server_name"] = sni }
        if params["insecure"] == "1" { tlsObj["insecure"] = true }
        ob["tls"] = tlsObj

        if let obfs = params["obfs"] {
            ob["obfs"] = ["type": obfs, "password": params["obfs-password"] ?? ""]
        }

        return ob
    }

    // MARK: - TLS Builder

    private static func buildTLS(params: [String: String]) -> [String: Any] {
        var tls: [String: Any] = ["enabled": true]

        if let sni = params["sni"], !sni.isEmpty { tls["server_name"] = sni }

        if let fp = params["fp"], !fp.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }

        if params["security"] == "reality" {
            var reality: [String: Any] = ["enabled": true]
            if let pbk = params["pbk"] { reality["public_key"] = pbk }
            if let sid = params["sid"] { reality["short_id"]   = sid }
            tls["reality"] = reality
        }

        if let alpn = params["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.components(separatedBy: ",")
        }

        if params["allowInsecure"] == "1" { tls["insecure"] = true }

        return tls
    }

    // MARK: - Transport Builder

    private static func buildTransport(params: [String: String]) -> [String: Any]? {
        switch params["type"] ?? "tcp" {
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            if let path = params["path"], !path.isEmpty { t["path"] = path.removingPercentEncoding ?? path }
            if let host = params["host"], !host.isEmpty { t["headers"] = ["Host": host] }
            return t
        case "grpc":
            var t: [String: Any] = ["type": "grpc"]
            if let svc = params["serviceName"] ?? params["grpcServiceName"], !svc.isEmpty { t["service_name"] = svc }
            return t
        case "h2":
            var t: [String: Any] = ["type": "http"]
            if let path = params["path"], !path.isEmpty { t["path"] = path }
            if let host = params["host"], !host.isEmpty { t["host"] = [host] }
            return t
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade"]
            if let path = params["path"], !path.isEmpty { t["path"] = path }
            if let host = params["host"], !host.isEmpty { t["host"] = host }
            return t
        default:
            return nil
        }
    }

    private static func buildVmessTransport(json: [String: Any], network: String) -> [String: Any]? {
        let path       = json["path"] as? String ?? ""
        let host       = json["host"] as? String ?? ""
        let headerType = json["type"] as? String ?? ""

        switch network {
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            if !path.isEmpty { t["path"] = path }
            if !host.isEmpty { t["headers"] = ["Host": host] }
            return t
        case "grpc":
            var t: [String: Any] = ["type": "grpc"]
            if !path.isEmpty { t["service_name"] = path }
            return t
        case "h2":
            var t: [String: Any] = ["type": "http"]
            if !path.isEmpty { t["path"] = path }
            if !host.isEmpty { t["host"] = [host] }
            return t
        case "tcp" where headerType == "http":
            var t: [String: Any] = ["type": "http"]
            if !path.isEmpty { t["path"] = path }
            if !host.isEmpty { t["host"] = [host] }
            return t
        default:
            return nil
        }
    }

    // MARK: - Config Assembly

    private static func assembleConfig(proxyOutbounds: [[String: Any]], proxyTags: [String]) -> [String: Any] {
        let selector: [String: Any] = [
            "type":      "selector",
            "tag":       "proxy",
            "outbounds": proxyTags + ["direct"],
            "default":   proxyTags[0]
        ]

        // Attach domain_resolver so each proxy outbound resolves its server hostname
        // via the local bootstrap DNS, avoiding circular dependency with remote DNS.
        let proxyWithResolver = proxyOutbounds.map { ob -> [String: Any] in
            var m = ob; m["domain_resolver"] = "bootstrap"; return m
        }

        var outbounds: [[String: Any]] = [selector]
        outbounds.append(contentsOf: proxyWithResolver)
        outbounds.append(contentsOf: [
            ["type": "direct", "tag": "direct", "domain_resolver": "bootstrap"],
            ["type": "block",  "tag": "block"]
        ])

        return [
            "log": ["level": "info", "timestamp": true],
            "dns": [
                "servers": [
                    [
                        "tag":         "remote",
                        "type":        "tls",
                        "server":      "1.1.1.1",
                        "server_port": 853,
                        "detour":      "proxy"
                    ],
                    [
                        "tag":         "bootstrap",
                        "type":        "udp",
                        "server":      "223.5.5.5",
                        "server_port": 53,
                        "detour":      "direct"
                    ]
                ],
                "final":             "remote",
                "strategy":          "prefer_ipv4",
                "independent_cache": true
            ],
            "inbounds": [
                [
                    "type":         "tun",
                    "tag":          "tun-in",
                    "address":      ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    "auto_route":   true,
                    "strict_route": true,
                    "stack":        "mixed"
                ],
                ["type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 2080]
            ],
            "outbounds": outbounds,
            "route": [
                "auto_detect_interface": true,
                "final":                 "proxy",
                "rules": [
                    ["action": "sniff", "override_destination": true],
                    ["protocol": "dns",        "action":  "hijack-dns"],
                    ["ip_is_private": true,    "outbound": "direct"]
                ]
            ]
        ]
    }

    // MARK: - Helpers

    private static func uniqueTag(_ base: String, usedTags: inout Set<String>) -> String {
        let clean = base.isEmpty ? "proxy" : base
        if usedTags.insert(clean).inserted { return clean }
        var i = 2
        while true {
            let c = "\(clean) \(i)"
            if usedTags.insert(c).inserted { return c }
            i += 1
        }
    }

    private static func queryDict(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        components.queryItems?.forEach { if let v = $0.value { result[$0.name] = v } }
        return result
    }

    /// Percent-encodes only the fragment part of a URI string so URLComponents can parse it.
    private static func preEncodeFragment(_ uri: String) -> String {
        guard let hashRange = uri.range(of: "#") else { return uri }
        let fragment = String(uri[uri.index(after: hashRange.lowerBound)...])
        guard let encoded = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return uri }
        return String(uri[uri.startIndex..<hashRange.lowerBound]) + "#" + encoded
    }

    private static func decodeBase64(_ s: String) -> Data? {
        for candidate in [s, s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")] {
            let padded = candidate + String(repeating: "=", count: (4 - candidate.count % 4) % 4)
            if let data = Data(base64Encoded: padded) { return data }
        }
        return nil
    }

    private static func decodeBase64String(_ s: String) -> String? {
        guard let data = decodeBase64(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
