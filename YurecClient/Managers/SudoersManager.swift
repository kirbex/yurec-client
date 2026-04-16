import Foundation

/// Manages the /etc/sudoers.d/yurec rule that allows running sing-box and
/// networksetup as root without a password prompt.
///
/// Flow:
///   1. On first Enable: call install(binaryPath:) — one osascript password dialog.
///   2. All subsequent starts/stops use `sudo -n` with no UI at all.
enum SudoersManager {

    static let rulePath = "/etc/sudoers.d/yurec"

    // MARK: - Public API

    /// True when sudo allows running binaryPath without a password.
    /// Uses `sudo -n -l` — works regardless of file permissions on the rule.
    static func isInstalled(for binaryPath: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", binaryPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let allowed = task.terminationStatus == 0
        print("[YurecClient] SudoersManager: isInstalled(\((binaryPath as NSString).lastPathComponent)) = \(allowed)")
        return allowed
    }

    /// Writes the sudoers rule. Shows exactly one password dialog (osascript).
    /// Returns true on success.
    @discardableResult
    static func install(binaryPath: String) -> Bool {
        let rule = buildRule(binaryPath: binaryPath)
        let tempPath = "/tmp/.yurec-sudoers"

        guard (try? rule.write(toFile: tempPath, atomically: true, encoding: .utf8)) != nil else {
            print("[YurecClient] SudoersManager: failed to write temp file")
            return false
        }

        // visudo -c validates syntax before we copy — prevents locking out sudo on a bad file
        let cmd = "visudo -c -f \(tempPath) && chmod 440 \(tempPath) && cp \(tempPath) \(rulePath) && rm -f \(tempPath)"
        let script = "do shell script \"\(appleScriptEscape(cmd))\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let err = error {
            print("[YurecClient] SudoersManager: install failed: \(err)")
            return false
        }
        print("[YurecClient] SudoersManager: rule installed at \(rulePath)")
        return true
    }

    /// Removes the rule (e.g. from a Settings "Revoke access" button).
    static func remove() {
        let script = "do shell script \"rm -f \(rulePath)\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        print("[YurecClient] SudoersManager: rule removed")
    }

    // MARK: - Private

    private static func buildRule(binaryPath: String) -> String {
        var binaries = ["/usr/local/bin/sing-box", "/opt/homebrew/bin/sing-box"]
        if !binaries.contains(binaryPath) { binaries.append(binaryPath) }
        let cmds = (binaries + ["/bin/kill", "/usr/sbin/networksetup"]).joined(separator: ", ")
        return "# Managed by YurecClient — do not edit\n%admin ALL=(root) NOPASSWD: \(cmds)\n"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
