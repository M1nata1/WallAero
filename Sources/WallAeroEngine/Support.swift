import AppKit
import os
import ServiceManagement
import WallpaperCore

/// View with: log stream --predicate 'subsystem == "com.fadevec.WallAeroEngine"'
enum Log {
    static let playback = Logger(subsystem: "com.fadevec.WallAeroEngine", category: "playback")
    static let cursor = Logger(subsystem: "com.fadevec.WallAeroEngine", category: "cursor")
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

extension Wallpaper {
    var resolutionText: String {
        "\(pixelWidth)×\(pixelHeight)"
    }

    var durationText: String? {
        guard let duration else { return nil }
        if duration < 60 {
            // The user's locale picks the decimal separator ("22,4 с" in Russian), as for file sizes.
            return String(format: NSLocalizedString("%.1f s", comment: "Loop length in seconds"), locale: .current, duration)
        }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// One line of details for the library: "1920×1080 · 12.0 s · 24 MB".
    var detailsText: String {
        [resolutionText, durationText, fileSizeText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Library thumbnails are tiny JPEGs, but the grid asks for them on every redraw.
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
