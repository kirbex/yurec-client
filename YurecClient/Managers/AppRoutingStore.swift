import Foundation
import Combine

/// Single source of truth for app-routing configuration across two tiers:
///
///   **Global** — default list applied to every profile that has not opted in to override.
///   **Per-profile** — profile-specific list that replaces global when `overridesGlobal` is true.
///
/// Resolution rule (see `effectiveEntries(for:)`):
///   - profile is nil            → global list
///   - profile.overridesGlobal   → profile-specific list
///   - otherwise                 → global list
///
/// Only `globalEntries` is @Published because it is observed reactively in the UI.
/// Per-profile entries are loaded on demand (settings screen is not always open).
final class AppRoutingStore: ObservableObject {
    static let shared = AppRoutingStore()

    @Published private(set) var globalEntries: [AppRoutingEntry]

    private init() {
        globalEntries = Self.load(key: Keys.global)
    }

    // MARK: - Global list

    func addGlobal(_ entry: AppRoutingEntry) {
        guard !globalEntries.contains(where: { $0.processName == entry.processName }) else { return }
        globalEntries.append(entry)
        Self.save(globalEntries, key: Keys.global)
    }

    func removeGlobal(id: UUID) {
        globalEntries.removeAll { $0.id == id }
        Self.save(globalEntries, key: Keys.global)
    }

    func setGlobal(_ entries: [AppRoutingEntry]) {
        globalEntries = entries
        Self.save(entries, key: Keys.global)
    }

    // MARK: - Per-profile list

    func entries(for profile: Profile) -> [AppRoutingEntry] {
        Self.load(key: Keys.profileEntries(profile))
    }

    func setEntries(_ entries: [AppRoutingEntry], for profile: Profile) {
        Self.save(entries, key: Keys.profileEntries(profile))
    }

    func overridesGlobal(for profile: Profile) -> Bool {
        UserDefaults.standard.bool(forKey: Keys.profileOverride(profile))
    }

    func setOverridesGlobal(_ value: Bool, for profile: Profile) {
        UserDefaults.standard.set(value, forKey: Keys.profileOverride(profile))
    }

    // MARK: - Effective list resolution

    /// Returns the app list that will be used when SOCKS5 starts for `profile`.
    func effectiveEntries(for profile: Profile?) -> [AppRoutingEntry] {
        guard let profile else { return globalEntries }
        return overridesGlobal(for: profile) ? entries(for: profile) : globalEntries
    }

    /// Convenience: `process_name` strings ready for injection into the sing-box config.
    func effectiveProcessNames(for profile: Profile?) -> [String] {
        effectiveEntries(for: profile).map(\.processName)
    }

    // MARK: - Persistence

    private enum Keys {
        static let global = "appRouting.global.v1"
        static func profileEntries(_ p: Profile) -> String {
            "appRouting.profile.entries.\(p.path.absoluteString)"
        }
        static func profileOverride(_ p: Profile) -> String {
            "appRouting.profile.override.\(p.path.absoluteString)"
        }
    }

    private static func load(key: String) -> [AppRoutingEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let entries = try? JSONDecoder().decode([AppRoutingEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func save(_ entries: [AppRoutingEntry], key: String) {
        let data = try? JSONEncoder().encode(entries)
        UserDefaults.standard.set(data, forKey: key)
    }
}
