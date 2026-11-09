import Foundation

/// One-time move of what the app saved under its earlier name. Both the UserDefaults domain and the
/// Application Support folder follow the bundle id, so without this a rename looks like a fresh install:
/// no shortcut, no tool style, no translation API key.
///
/// Nothing is deleted — the old domain and folder are left where they are, so an older build still finds
/// its settings. Delete this file and its call in `Settings.init` once upgrading from the old name is no
/// longer a thing.
enum LegacyMigration {
    /// The bundle id the app used before the rename; the old defaults domain and support folder are both named after it.
    private static let legacyBundleID = "app.shotlate.Shotlate"
    private static let legacySupportFolder = "Shotlate"
    private static let marker = "migrated.from.legacy.app"

    /// Runs at most once per install. Unbundled dev builds are skipped on purpose: their defaults domain is
    /// the executable's name, and a scripted run (`--check`, `--ui-demo`) must never pick up the real app's
    /// settings — the same reason such a build reads the API key from the environment instead of the file.
    static func run(into defaults: UserDefaults) {
        guard Bundle.main.bundleIdentifier != nil, !defaults.bool(forKey: marker) else { return }
        copyDefaults(from: legacyBundleID, into: defaults)
        copySecretFiles()
        defaults.set(true, forKey: marker)
    }

    /// Copies every key the old domain has and the new one hasn't. An existing key always wins, so a
    /// setting the user has changed since the rename is never overwritten by the old one.
    static func copyDefaults(from legacyDomain: String, into defaults: UserDefaults) {
        guard let old = defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// The translation API key is the only file in there, and typing it in again would be a real loss.
    private static func copySecretFiles() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent(legacySupportFolder, isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for name in names {
            let source = old.appendingPathComponent(name)
            guard !fm.fileExists(atPath: SecretFile.directory.appendingPathComponent(name).path),
                  let value = try? String(contentsOf: source, encoding: .utf8) else { continue }
            SecretFile.write(value.trimmingCharacters(in: .whitespacesAndNewlines), name)
        }
    }
}
