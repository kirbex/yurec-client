import Foundation
import Combine
import Darwin

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning: Bool = false {
        didSet { print("[YurecClient] isRunning changed: \(oldValue) → \(isRunning)") }
    }
    @Published var currentMode: ConnectionMode?

    private var runningPID: Int32?
    private var runningProcess: Process?  // strong ref so process isn't deallocated
    private var statusTimer: Timer?
    private var binaryPath: String = ""
    private var tempConfigURL: URL?   // temp file for SOCKS5 transformed config

    private init() {
        print("[YurecClient] ProxyManager.init: start")
        binaryPath = resolveBinaryPath()
        print("[YurecClient] ProxyManager.init: binaryPath=\(binaryPath)")
        setupSignalHandlers()
        setupAtExit()
        print("[YurecClient] ProxyManager.init: done")
    }

    // MARK: - Binary Resolution

    private func resolveBinaryPath() -> String {
        if let override = UserDefaults.standard.string(forKey: "yurecBinaryPath"), !override.isEmpty {
            return override
        }
        let candidates = [
            "/usr/local/bin/sing-box",
            "/opt/homebrew/bin/sing-box"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["sing-box"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? "/usr/local/bin/sing-box" : result
    }

    func updateBinaryPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: "yurecBinaryPath")
        binaryPath = path.isEmpty ? resolveBinaryPath() : path
    }

    var currentBinaryPath: String { binaryPath }

    /// Path for sing-box stdout/stderr log. User-owned so the shell can create it.
    static var singBoxLogURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/YurecClient")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sing-box.log")
    }()

    // MARK: - Process Lifecycle

    func start(profilePath: String, mode: ConnectionMode = .tun) {
        guard !isRunning else { return }
        stopLaunchDetectionLoop()

        // Kill any orphaned sing-box process that may be running but not tracked by this app
        // (e.g. a previous session's process that left isRunning=false)
        killOrphanedSingBox(forMode: mode)

        // Resolve the actual config path
        let configPath: String
        switch mode {
        case .tun:
            // Use the profile as-is — socks-in inbound stays so Telegram and other
            // apps configured to use the local SOCKS proxy continue to work in TUN mode.
            configPath = profilePath

        case .socks5(let port):
            // Second-pass port check: even if killOrphanedSingBox ran, something may still
            // hold the port (orphan that pgrep missed, or an unrelated process).
            if !ensurePortFreeForSocks5(port) {
                // Port held by a non-sing-box process — already logged, abort cleanly.
                return
            }
            let activeProfile = ProfileManager.shared.profiles.first { $0.path.path == profilePath }
            let routedNames = AppRoutingStore.shared.effectiveProcessNames(for: activeProfile)
            guard let tmpURL = try? ConfigTransformer.makeSocks5Config(from: profilePath, port: port, routedProcessNames: routedNames) else {
                print("[YurecClient] start: failed to transform config for SOCKS5")
                return
            }
            tempConfigURL = tmpURL
            configPath = tmpURL.path
        }

        // Both modes require root. Also ensure networksetup is covered so the
        // SOCKS5 system proxy helper can run without a password.
        if mode.requiresRoot {
            let needsInstall = !SudoersManager.isInstalled(for: binaryPath)
                || !SudoersManager.isInstalled(for: "/usr/sbin/networksetup")
            if needsInstall {
                guard SudoersManager.install(binaryPath: binaryPath) else {
                    print("[YurecClient] start: sudoers install failed, aborting")
                    return
                }
            }
        }

        // Open (or create) the log file in append mode.
        // We do NOT truncate — previous session errors must survive so they can be
        // inspected even if a subsequent mode switch overwrites the file handle.
        // A session separator line marks where each new run begins.
        let logURL = ProxyManager.singBoxLogURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let outHandle = FileHandle(forWritingAtPath: logURL.path) else {
            print("[YurecClient] start: cannot open log file at \(logURL.path)")
            return
        }
        // Seek to end (append) and write a timestamped session separator
        outHandle.seekToEndOfFile()
        let separator = "\n\n--- YurecClient: starting \(mode) @ \(Date()) ---\n\n"
        outHandle.write(Data(separator.utf8))

        // dup() the fd so stdout and stderr get independent file descriptors pointing to
        // the same log file. Using the SAME FileHandle for both can cause NSTask to silently
        // drop one of the redirections (it may close the source fd after the first dup2).
        let dupFd = dup(outHandle.fileDescriptor)
        let errHandle: FileHandle = dupFd >= 0
            ? FileHandle(fileDescriptor: dupFd, closeOnDealloc: true)
            : outHandle

        // Build the process directly — no sh wrapper, no pipe dance, no PID parsing.
        // Process.processIdentifier gives us a reliable PID, terminationHandler fires on exit.
        let task = Process()
        if mode.requiresRoot {
            // TUN: sudo -n /path/to/sing-box run -c config.json
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", binaryPath, "run", "-c", configPath]
        } else {
            // SOCKS5: /path/to/sing-box run -c config.json  (no root needed)
            task.executableURL = URL(fileURLWithPath: binaryPath)
            task.arguments = ["run", "-c", configPath]
        }
        task.standardOutput = outHandle
        task.standardError = errHandle

        guard (try? task.run()) != nil else {
            print("[YurecClient] start: failed to launch process")
            outHandle.closeFile()
            errHandle.closeFile()
            return
        }
        // Parent no longer needs the file handles; the child has its own fd copies
        outHandle.closeFile()
        errHandle.closeFile()

        let pid = task.processIdentifier
        print("[YurecClient] start: launched PID=\(pid) mode=\(mode)")

        runningProcess = task
        runningPID = pid
        currentMode = mode

        // Set isRunning SYNCHRONOUSLY before registering the terminationHandler.
        // If the process dies instantly (e.g. SOCKS5 port TIME_WAIT), the handler
        // is dispatched immediately upon assignment — if isRunning were set async,
        // handleProcessTermination() would see isRunning=false and bail before retry.
        // start() is always called on the main thread, so this is safe.
        isRunning = true

        // terminationHandler is called on an arbitrary thread when the process exits
        task.terminationHandler = { [weak self] proc in
            print("[YurecClient] terminationHandler: PID=\(proc.processIdentifier) status=\(proc.terminationStatus)")
            DispatchQueue.main.async { self?.handleProcessTermination() }
        }

        // Apply mode-specific system networking:
        //   TUN  → override DNS so sing-box handles resolution via its fake-ip stack.
        //   SOCKS5 → set macOS system proxy so all apps automatically route through
        //            the local sing-box inbound without manual per-app configuration.
        switch mode {
        case .tun:
            DNSHelper.setDNS("172.19.0.1")
        case .socks5(let port):
            SystemProxyHelper.enableSOCKS5(port: port)
        }
    }

    func stop() {
        guard isRunning else { return }
        stopKqueueWatch()
        // SIGKILL any root sing-box child processes. Both TUN and SOCKS5 now run as
        // root, so we kill them the same way regardless of mode.
        let sbPids = pgrepSingBox()
        if !sbPids.isEmpty {
            print("[YurecClient] stop: SIGKILL sing-box child PIDs=\(sbPids)")
            forceKillPIDs(sbPids, label: "stop")
        }
        killProcess()
        if currentMode == .tun { DNSHelper.resetDNS() }
        if case .socks5 = currentMode { SystemProxyHelper.disableSOCKS5() }
        cleanupMode()
        isRunning = false
        // Start watching for sing-box to appear again (user may start it externally).
        // If start() is called right after (mode-switch), it cancels this loop immediately.
        startLaunchDetectionLoop()
    }

    private func cleanupMode() {
        if let url = tempConfigURL {
            try? FileManager.default.removeItem(at: url)
            tempConfigURL = nil
        }
        currentMode = nil
        runningProcess = nil
        runningPID = nil
    }

    private func killProcess() {
        // Terminate our direct Process reference
        if let proc = runningProcess, proc.isRunning {
            proc.terminate()
        }
        // Also kill by PID in case proc.terminate() didn't reach the root child
        if let pid = runningPID {
            if kill(pid, SIGTERM) != 0 && errno == EPERM {
                sudoKill(pid: pid)
            }
        }
    }

    /// Returns PIDs of all running sing-box processes via pgrep.
    /// More reliable than sysctl from a GUI app context.
    private func pgrepSingBox() -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "sing-box"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Kills any running sing-box processes (orphaned from a previous session) and waits
    /// until they are gone before returning. Uses SIGKILL to avoid leaving TIME_WAIT
    /// entries on the port — critical so the next start() can bind immediately.
    private func killOrphanedSingBox(forMode mode: ConnectionMode? = nil) {
        let pids = pgrepSingBox()
        guard !pids.isEmpty else { return }
        print("[YurecClient] killOrphanedSingBox: found PIDs=\(pids), SIGKILL")
        forceKillPIDs(pids, label: "killOrphanedSingBox")
    }

    /// Sends SIGKILL to each PID (using sudo for root processes), then polls until
    /// all are confirmed dead (max 2 s). SIGKILL causes the kernel to RST open TCP
    /// connections — no TIME_WAIT, so the port is usable immediately after return.
    private func forceKillPIDs(_ pids: [Int32], label: String) {
        for pid in pids {
            if kill(pid, SIGKILL) != 0 && errno == EPERM {
                // Root process — need sudo
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/bin/sh")
                t.arguments = ["-c", "sudo -n /bin/kill -9 \(pid) 2>/dev/null"]
                t.standardOutput = Pipe(); t.standardError = Pipe()
                try? t.run(); t.waitUntilExit()
            }
        }
        // Poll until all are gone (max 2 s — SIGKILL is near-instant)
        for i in 1...20 {
            Thread.sleep(forTimeInterval: 0.1)
            let alive = pids.filter { kill($0, 0) == 0 || errno == EPERM }
            if alive.isEmpty {
                print("[YurecClient] \(label): all PIDs gone after \(i * 100)ms")
                return
            }
        }
        print("[YurecClient] \(label): some PIDs still alive after 2s (unexpected)")
    }

    /// Returns true if something is actively listening on 127.0.0.1:port.
    ///
    /// Uses connect() instead of bind() — this is the semantically correct check:
    ///   connect() → 0          : a process accepted our connection → listener exists
    ///   connect() → ECONNREFUSED: nobody is listening → port is free
    ///
    /// bind() is NOT used because it returns EADDRINUSE for TIME_WAIT / CLOSE_WAIT
    /// residue even after the process is dead, causing false positives.
    private func hasListenerOnPort(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        // RST on close so the server-side (if any) isn't left with a dangling connection
        var lg = linger(l_onoff: 1, l_linger: 0)
        setsockopt(sock, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            // Connected — someone is listening
            return true
        }
        let err = errno
        if err == ECONNREFUSED {
            return false   // no listener
        }
        // Any other error (ETIMEDOUT, etc.) — assume no listener to avoid false positives
        print("[YurecClient] hasListenerOnPort(\(port)): unexpected errno=\(err) (\(String(cString: strerror(err))))")
        return false
    }

    /// Checks whether port is safe to hand to SOCKS5 sing-box.
    ///
    /// Decision tree:
    ///   1. No listener detected (connect → ECONNREFUSED) : proceed immediately.
    ///   2. Listener found, pgrep finds sing-box           : SIGKILL it, proceed.
    ///   3. Listener found, pgrep finds nothing            :
    ///        a. lsof identifies a non-sing-box process    → warn + abort.
    ///        b. lsof finds nothing (root process?)        → warn + abort (unknown holder).
    ///
    /// Returns false only when a foreign listener is detected and we cannot remove it.
    @discardableResult
    private func ensurePortFreeForSocks5(_ port: Int) -> Bool {
        guard hasListenerOnPort(port) else { return true }

        // Something is listening. Is it sing-box?
        let singBoxPIDs = pgrepSingBox()
        if !singBoxPIDs.isEmpty {
            print("[YurecClient] ensurePortFreeForSocks5: port \(port) held by sing-box PIDs=\(singBoxPIDs), SIGKILL")
            forceKillPIDs(singBoxPIDs, label: "ensurePortFreeForSocks5")
            return true
        }

        // A non-sing-box process is listening. Log and abort.
        let listenInfo = diagnosticForPort(port)
        let detail = listenInfo.isEmpty ? "(root process — lsof requires sudo to identify)" : listenInfo
        print("[YurecClient] ensurePortFreeForSocks5: port \(port) is held by a non-sing-box process: \(detail)")
        print("[YurecClient]   → Change the SOCKS5 port in Settings.")
        return false
    }

    /// Runs lsof to identify which process(es) are listening on the given port.
    /// Returns a human-readable string suitable for log output, or empty string on failure.
    private func diagnosticForPort(_ port: Int) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // lsof header line + process line(s); strip ANSI just in case
        guard !out.isEmpty else { return "" }  // lsof found nothing (may lack root visibility)
        // Return the non-header lines as compact info
        let lines = out.split(separator: "\n").dropFirst()  // skip "COMMAND PID USER..." header
        let info = lines.map { String($0) }.joined(separator: "; ")
        return info.isEmpty ? "" : ": \(info)"
    }

    private func sudoKill(pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sudo -n /bin/kill -TERM \(pid) 2>/dev/null"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    private func handleProcessTermination() {
        // If stop() already cleaned up (set isRunning=false), do nothing.
        // This prevents the terminationHandler from clobbering state when
        // stop() is immediately followed by start() for mode-switching.
        guard isRunning else { return }
        if currentMode == .tun { DNSHelper.resetDNS() }
        if case .socks5 = currentMode { SystemProxyHelper.disableSOCKS5() }
        cleanupMode()
        isRunning = false
        startLaunchDetectionLoop()
    }

    /// Adopts a sing-box process found externally (detection loop / app launch).
    /// We don't have a Process reference so we poll via kqueue.
    private func adoptProcess(pid: Int32, profilePath: String?) {
        stopLaunchDetectionLoop()
        runningPID = pid
        isRunning = true
        if let path = profilePath {
            ProfileManager.shared.activateProfileByPath(path)
        }
        // Watch the adopted process with kqueue (we have no Process ref for terminationHandler)
        startKqueueWatchAsync(pid: pid)
    }

    // MARK: - kqueue watch for adopted processes

    private var watchingProcess = false

    private func startKqueueWatchAsync(pid: Int32) {
        watchingProcess = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.startKqueueWatch(pid: pid) {
                print("[YurecClient] watching adopted PID \(pid) via kqueue")
            } else {
                print("[YurecClient] kqueue unavailable for PID \(pid), falling back to polling")
                self.runPollingLoop(pid: pid)
            }
        }
    }

    private func stopKqueueWatch() {
        watchingProcess = false
    }

    /// Blocks a background thread until the process exits (kqueue EVFILT_PROC).
    /// Returns true if we successfully registered; false if no access (use polling instead).
    private func startKqueueWatch(pid: Int32) -> Bool {
        let kq = kqueue()
        guard kq != -1 else { return false }
        defer { close(kq) }

        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return false }

        var event = kevent()
        while watchingProcess {
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            let n = kevent(kq, nil, 0, &event, 1, &timeout)
            if n > 0 {
                print("[YurecClient] kqueue: adopted PID \(pid) exited")
                if watchingProcess {
                    DispatchQueue.main.async { [weak self] in self?.handleProcessTermination() }
                }
                return true
            }
        }
        return true
    }

    private func runPollingLoop(pid: Int32) {
        while watchingProcess {
            Thread.sleep(forTimeInterval: 2.0)
            guard watchingProcess else { break }
            if kill(pid, 0) != 0 && errno == ESRCH {
                print("[YurecClient] polling: adopted PID \(pid) no longer exists")
                DispatchQueue.main.async { [weak self] in self?.handleProcessTermination() }
                return
            }
        }
    }

    // MARK: - Process Detection

    /// При старте: если sing-box уже запущен — подхватываем, иначе — начинаем следить за запуском.
    func detectExistingProcess() {
        guard !isRunning else { return }
        print("[YurecClient] detectExistingProcess: start")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            if let pid = self.findSingBoxPID() {
                let profilePath = self.readProfilePath(pid: pid)
                print("[YurecClient] detectExistingProcess: found PID=\(pid) profile=\(profilePath ?? "unknown")")
                DispatchQueue.main.async { self.adoptProcess(pid: pid, profilePath: profilePath) }
            } else {
                print("[YurecClient] detectExistingProcess: not running, watching for launch...")
                self.startLaunchDetectionLoop()
            }
        }
    }

    // MARK: - Launch Detection

    private var detectingLaunch = false

    /// Polling-петля: ждём когда sing-box появится в системе (запущен вручную или другим способом).
    /// Работает только когда isRunning = false. Останавливается сразу при обнаружении.
    private func startLaunchDetectionLoop() {
        guard !detectingLaunch else { return }
        detectingLaunch = true
        print("[YurecClient] launch detection: watching for sing-box to start...")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var checkCount = 0
            while let self, self.detectingLaunch, !self.isRunning {
                Thread.sleep(forTimeInterval: 2.0)
                guard self.detectingLaunch, !self.isRunning else { break }
                checkCount += 1

                if let pid = self.findSingBoxPID(silent: true) {
                    let profilePath = self.readProfilePath(pid: pid)
                    print("[YurecClient] launch detection: sing-box appeared, PID=\(pid) profile=\(profilePath ?? "unknown")")
                    DispatchQueue.main.async { self.adoptProcess(pid: pid, profilePath: profilePath) }
                    return
                }

                // Log only on first check and then every 30 seconds to avoid spam
                if checkCount == 1 || checkCount % 15 == 0 {
                    print("[YurecClient] launch detection: waiting... (\(checkCount * 2)s)")
                }
            }
            print("[YurecClient] launch detection: stopped")
        }
    }

    private func stopLaunchDetectionLoop() {
        detectingLaunch = false
    }

    /// Возвращает PID процесса sing-box через sysctl (без fork/exec).
    /// Сканирует таблицу процессов ядра, ищет p_comm == "sing-box",
    /// затем проверяет аргументы (KERN_PROCARGS2) на наличие "run".
    /// `silent`: suppress the "not found" log line (used in tight polling loops).
    private func findSingBoxPID(silent: Bool = false) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        // Первый вызов — узнаём нужный размер буфера
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            print("[YurecClient] sysctl: size query failed, errno=\(errno)")
            return nil
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        // Второй вызов — заполняем буфер (размер мог чуть вырасти)
        var actualSize = size
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else {
            print("[YurecClient] sysctl: proc list fetch failed, errno=\(errno)")
            return nil
        }

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride

        // kp_proc.p_comm — массив CChar, максимум MAXCOMLEN (16) символов
        var candidates: [Int32] = []
        var singLike: [String] = []   // для диагностики — имена близкие к "sing"
        for i in 0 ..< actualCount {
            let name = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name == "sing-box" {
                candidates.append(procs[i].kp_proc.p_pid)
            } else if name.hasPrefix("sing") || name.contains("box") {
                singLike.append("\(name)[\(procs[i].kp_proc.p_pid)]")
            }
        }

        if candidates.isEmpty {
            if !silent {
                let hint = singLike.isEmpty ? "no similar names found" : "similar: \(singLike)"
                print("[YurecClient] sysctl: sing-box not found (\(actualCount) procs scanned, \(hint))")
            }
            return nil
        }
        print("[YurecClient] sysctl: sing-box candidates: \(candidates)")

        // Если несколько PIDs — фильтруем по наличию "run" в аргументах,
        // чтобы не подхватить sing-box version / sing-box help и т.п.
        let running = candidates.filter { hasRunArg(pid: $0) }
        let result = (running.isEmpty ? candidates : running).max()
        print("[YurecClient] sysctl: selected PID \(result as Any)")
        return result
    }

    /// Возвращает путь к конфигу из аргументов процесса через KERN_PROCARGS2.
    private func readProfilePath(pid: Int32) -> String? {
        guard let args = readProcArgs(pid: pid) else { return nil }
        print("[YurecClient] KERN_PROCARGS2 args for PID \(pid): \(args)")
        guard let idx = args.firstIndex(of: "-c"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// true если аргументы процесса содержат "run" (sing-box run -c …)
    private func hasRunArg(pid: Int32) -> Bool {
        readProcArgs(pid: pid)?.contains("run") ?? false
    }

    /// Читает argv процесса через sysctl KERN_PROCARGS2.
    /// Формат буфера: Int32 argc | exec_path\0 | padding\0… | arg0\0 | arg1\0 | …
    private func readProcArgs(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Первые 4 байта — argc (Int32 little-endian)
        guard size >= 4 else { return nil }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24

        // Пропускаем exec_path (строка до первого \0) и padding (нули до следующей строки)
        var offset = 4
        while offset < size, buf[offset] != 0 { offset += 1 } // конец exec_path
        while offset < size, buf[offset] == 0 { offset += 1 } // паддинг

        // Читаем argc аргументов
        var args: [String] = []
        for _ in 0 ..< argc {
            guard offset < size else { break }
            var end = offset
            while end < size, buf[end] != 0 { end += 1 }
            if let s = String(bytes: buf[offset ..< end], encoding: .utf8) {
                args.append(s)
            }
            offset = end + 1
        }
        return args
    }

    // MARK: - Signal Handlers

    private func setupSignalHandlers() {
        signal(SIGTERM) { _ in ProxyManager.shared.forceCleanup() }
        signal(SIGINT)  { _ in ProxyManager.shared.forceCleanup() }
    }

    private func setupAtExit() {
        atexit { ProxyManager.shared.forceCleanup() }
    }

    func forceCleanup() {
        stopLaunchDetectionLoop()
        stopKqueueWatch()
        if let proc = runningProcess, proc.isRunning { proc.terminate() }
        if let pid = runningPID {
            if kill(pid, SIGTERM) != 0 && errno == EPERM {
                sudoKill(pid: pid)
            }
        }
        if currentMode == .tun { DNSHelper.resetDNS() }
        if case .socks5 = currentMode { SystemProxyHelper.disableSOCKS5() }
        if let url = tempConfigURL { try? FileManager.default.removeItem(at: url) }
        runningPID = nil
        runningProcess = nil
    }

    // MARK: - Helpers

    /// Single-quotes a string for safe use in a POSIX shell command.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
