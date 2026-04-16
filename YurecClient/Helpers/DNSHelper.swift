import Foundation
import SystemConfiguration

/// Sets and resets DNS servers for all enabled network services.
/// Uses `sudo -n /usr/sbin/networksetup` (allowed without a password via
/// the sudoers rule installed by SudoersManager).
enum DNSHelper {

    static func setDNS(_ server: String) {
        forEachEnabledService { name in
            runSudo("/usr/sbin/networksetup -setdnsservers \(shellQuote(name)) \(shellQuote(server))")
        }
    }

    static func resetDNS() {
        forEachEnabledService { name in
            runSudo("/usr/sbin/networksetup -setdnsservers \(shellQuote(name)) empty")
        }
    }

    // MARK: - Private

    /// Iterates over every enabled network service, passing its display name to block.
    private static func forEachEnabledService(_ block: (String) -> Void) {
        guard let prefs = SCPreferencesCreate(nil, "YurecClient" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            print("[DNSHelper] failed to enumerate network services")
            return
        }
        for service in services {
            guard SCNetworkServiceGetEnabled(service),
                  let name = SCNetworkServiceGetName(service) as String? else { continue }
            block(name)
        }
    }

    private static func runSudo(_ cmd: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sudo -n \(cmd)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
