import Combine
import Foundation

/// The user's collection of wallpapers, stored in Application Support:
///
///     WallAeroEngine/
///       library.json   – the list of entries
///       Media/         – imported videos and pictures (animated images converted to .mov)
///       Thumbnails/    – small JPEG previews for the library window
///       Stills/        – full-size first frames, used as the regular macOS wallpaper
@MainActor
public final class WallpaperLibrary: ObservableObject {
    @Published public private(set) var items: [Wallpaper] = []

    public let rootURL: URL
    public let mediaURL: URL
    public let thumbnailsURL: URL
    public let stillsURL: URL
    private let indexURL: URL

    public nonisolated static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("WallAeroEngine", isDirectory: true)
    }

    /// Where the library lived while the app was called AiWallpaper; see `LegacyData`.
    public nonisolated static var legacyRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("AiWallpaper", isDirectory: true)
    }

    public init(rootURL: URL = WallpaperLibrary.defaultRootURL) {
        self.rootURL = rootURL
        mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        thumbnailsURL = rootURL.appendingPathComponent("Thumbnails", isDirectory: true)
        stillsURL = rootURL.appendingPathComponent("Stills", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("library.json")
        for directory in [mediaURL, thumbnailsURL, stillsURL] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Lookup

    public func item(withID id: UUID) -> Wallpaper? {
        items.first { $0.id == id }
    }

    public func fileURL(for item: Wallpaper) -> URL {
        mediaURL.appendingPathComponent(item.fileName)
    }

    public func thumbnailURL(for item: Wallpaper) -> URL? {
        item.thumbnailFileName.map { thumbnailsURL.appendingPathComponent($0) }
    }

    /// A full-size still of the wallpaper, suitable for `NSWorkspace.setDesktopImageURL`.
    /// For videos the first frame is extracted once and cached.
    public func stillImageURL(for item: Wallpaper) async throws -> URL {
        if item.kind == .image {
            return fileURL(for: item)
        }
        let stillURL = stillsURL.appendingPathComponent("\(item.id.uuidString).jpg")
        if FileManager.default.fileExists(atPath: stillURL.path) {
            return stillURL
        }
        let frame = try await Thumbnailer.frame(ofVideoAt: fileURL(for: item), at: 0, maxPixelSize: nil)
        try Thumbnailer.writeJPEG(frame, to: stillURL, quality: 0.92)
        return stillURL
    }

    // MARK: - Changes

    /// Copies (or converts) the file into the library and adds it to the top of the list.
    @discardableResult
    public func importFile(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Wallpaper {
        let destination = MediaImporter.Destination(mediaDirectory: mediaURL, thumbnailDirectory: thumbnailsURL)
        let item = try await MediaImporter.importMedia(from: url, id: UUID(), into: destination, progress: progress)
        items.insert(item, at: 0)
        save()
        return item
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = trimmed
        save()
    }

    /// Removes the entries and deletes their files.
    public func remove(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
        for item in removed {
            var files = [fileURL(for: item), stillsURL.appendingPathComponent("\(item.id.uuidString).jpg")]
            if let thumbnail = thumbnailURL(for: item) {
                files.append(thumbnail)
            }
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Wallpaper].self, from: data) else { return }
        // Entries whose media file disappeared (deleted by hand) are dropped.
        items = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
