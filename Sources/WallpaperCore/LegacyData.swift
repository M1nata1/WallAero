import Foundation

/// The app was called AiWallpaper before it became WallAero Engine, and kept its data in a folder
/// of that name. This moves such a folder's contents to where the app looks now.
public enum LegacyData {
    /// Moves everything in `old` into `new` and removes `old` once it is empty. Nothing in `new`
    /// is overwritten: where both have a file, the one in `new` wins and the old one stays put.
    /// Safe to call on every launch; it does nothing when `old` does not exist.
    public static func moveContents(of old: URL, into new: URL) {
        let fileManager = FileManager.default
        guard isDirectory(old) else { return }
        if !fileManager.fileExists(atPath: new.path) {
            try? fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The usual case, and instant: the folder just gets its new name.
            if (try? fileManager.moveItem(at: old, to: new)) != nil { return }
        }
        merge(old, into: new)
    }

    private static func merge(_ source: URL, into destination: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: item, to: target)
            } else if isDirectory(item), isDirectory(target) {
                merge(item, into: target)
            }
        }
        if let left = try? fileManager.contentsOfDirectory(atPath: source.path), left.isEmpty {
            try? fileManager.removeItem(at: source)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
