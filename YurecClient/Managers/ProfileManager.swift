import Foundation
import Combine
import AppKit

struct Profile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: URL

    init(path: URL) {
        self.id = UUID()
        self.name = path.deletingPathExtension().lastPathComponent
        self.path = path
    }
}

class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?

    private let profilesDir: URL
    private var fsEventStream: FSEventStreamRef?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        profilesDir = home.appendingPathComponent(".singbox/profiles")
        createProfilesDirIfNeeded()
        loadProfiles()
        restoreActiveProfile()
        startWatching()
    }

    // MARK: - Directory Setup

    private func createProfilesDirIfNeeded() {
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    // MARK: - Profile Loading

    func loadProfiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        let jsonFiles = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let newProfiles = jsonFiles.map { Profile(path: $0) }

        // Всегда вызывается из main queue (init + FSEvents через DispatchQueue.main)
        // Обновляем синхронно, чтобы restoreActiveProfile() видел актуальный список
        profiles = newProfiles
        if let active = activeProfile,
           !newProfiles.contains(where: { $0.path == active.path }) {
            activeProfile = newProfiles.first
            persistActiveProfile()
        }
    }

    private func restoreActiveProfile() {
        let stored = UserDefaults.standard.string(forKey: "activeProfilePath")
        if let stored = stored, let url = URL(string: stored) {
            activeProfile = profiles.first(where: { $0.path == url }) ?? profiles.first
        } else {
            activeProfile = profiles.first
        }
        persistActiveProfile()
    }

    func setActiveProfile(_ profile: Profile) {
        activeProfile = profile
        persistActiveProfile()
    }

    /// Ищет профиль по пути к файлу и делает его активным.
    func activateProfileByPath(_ path: String) {
        guard let match = profiles.first(where: { $0.path.path == path }) else { return }
        setActiveProfile(match)
    }

    private func persistActiveProfile() {
        UserDefaults.standard.set(activeProfile?.path.absoluteString, forKey: "activeProfilePath")
    }

    // MARK: - Profile CRUD

    func addProfile(from sourceURL: URL) throws {
        let destination = profilesDir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
    }

    func removeProfile(_ profile: Profile) throws {
        try FileManager.default.removeItem(at: profile.path)
    }

    func createNewProfile(name: String) throws {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        let destination = profilesDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists
        }
        let template = emptyProfileTemplate()
        try template.write(to: destination, atomically: true, encoding: .utf8)
    }

    func openInEditor(_ profile: Profile) {
        NSWorkspace.shared.open(profile.path)
    }

    // MARK: - Per-Profile Settings

    static let defaultSocks5Port = 2080

    func socks5Port(for profile: Profile) -> Int {
        let key = "socks5Port_\(profile.path.absoluteString)"
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : ProfileManager.defaultSocks5Port
    }

    func setSocks5Port(_ port: Int, for profile: Profile) {
        UserDefaults.standard.set(port, forKey: "socks5Port_\(profile.path.absoluteString)")
    }

    private func emptyProfileTemplate() -> String {
        """
        {
          "log": {
            "level": "info",
            "timestamp": true
          },
          "dns": {
            "servers": [
              {
                "tag": "remote",
                "address": "tls://1.1.1.1"
              }
            ]
          },
          "inbounds": [],
          "outbounds": [
            {
              "type": "direct",
              "tag": "direct"
            },
            {
              "type": "block",
              "tag": "block"
            }
          ],
          "route": {
            "final": "direct"
          }
        }
        """
    }

    // MARK: - FSEvents

    private func startWatching() {
        let paths = [profilesDir.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let manager = Unmanaged<ProfileManager>.fromOpaque(info).takeUnretainedValue()
            manager.loadProfiles()
        }

        fsEventStream = FSEventStreamCreate(
            nil,
            callback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = fsEventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

enum ProfileError: LocalizedError {
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .alreadyExists: return "A profile with that name already exists."
        }
    }
}
