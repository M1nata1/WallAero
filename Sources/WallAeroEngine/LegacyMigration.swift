import AppKit
import WallpaperCore

/// The app was called AiWallpaper (com.fadevec.AiWallpaper) before it became WallAero Engine.
/// On the first launch under the new name its library, cursor backups and settings move over, so
/// an update loses nothing. Has to run before the library and the preferences are created.
@MainActor
enum LegacyMigration {
    private static let oldBundleID = "com.fadevec.AiWallpaper"
    private static let settingsImportedKey = "importedAiWallpaperSettings"

    static func run() {
        let defaults = UserDefaults.standard
        let hasOldData = FileManager.default.fileExists(atPath: WallpaperLibrary.legacyRootURL.path)
        let needsSettings = !defaults.bool(forKey: settingsImportedKey)
        guard hasOldData || needsSettings else { return }

        quitOldApp()
        if needsSettings {
            importSettings(into: defaults)
            defaults.set(true, forKey: settingsImportedKey)
        }
        LegacyData.moveContents(of: WallpaperLibrary.legacyRootURL, into: WallpaperLibrary.defaultRootURL)
    }

    /// A copy still running under the old name would keep writing to the folder being moved.
    private static func quitOldApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Copies the old settings, window positions included, without replacing anything already set.
    private static func importSettings(into defaults: UserDefaults) {
        // Run outside an app bundle (`swift run`), the old app kept its settings under its bare name.
        for domain in [oldBundleID, "AiWallpaper"] {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            let own = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
            for (key, value) in old where own[key] == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
