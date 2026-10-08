import Combine
import CoreGraphics
import Foundation

/// The user's collection of wallpapers, stored in Application Support:
///
///     WallAeroEngine/
///       library.json   – the list of entries
///       Media/         – imported videos and pictures (animated images converted to .mov)
///       Thumbnails/    – small JPEG previews for the library window
///       Stills/        – full-size first frames, used as the regular macOS wallpaper
///       Web/           – one folder per web wallpaper: scenes and imported pages
@MainActor
public final class WallpaperLibrary: ObservableObject {
    @Published public private(set) var items: [Wallpaper] = []

    public let rootURL: URL
    public let mediaURL: URL
    public let thumbnailsURL: URL
    public let stillsURL: URL
    public let webURL: URL
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
        webURL = rootURL.appendingPathComponent("Web", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("library.json")
        for directory in [mediaURL, thumbnailsURL, stillsURL, webURL] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Lookup

    public func item(withID id: UUID) -> Wallpaper? {
        items.first { $0.id == id }
    }

    /// The video or picture; for a web wallpaper, its page.
    public func fileURL(for item: Wallpaper) -> URL {
        (item.kind == .web ? webURL : mediaURL).appendingPathComponent(item.fileName)
    }

    /// The folder of a web wallpaper, with its page and everything the page uses.
    public func projectURL(for item: Wallpaper) -> URL {
        webURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
    }

    public func stillURL(for item: Wallpaper) -> URL {
        stillsURL.appendingPathComponent("\(item.id.uuidString).jpg")
    }

    public func thumbnailURL(for item: Wallpaper) -> URL? {
        item.thumbnailFileName.map { thumbnailsURL.appendingPathComponent($0) }
    }

    /// A full-size still of the wallpaper, suitable for `NSWorkspace.setDesktopImageURL`.
    /// For videos the first frame is extracted once and cached. A web wallpaper has a still only
    /// after the app has rendered one, see `setStill`.
    public func stillImageURL(for item: Wallpaper) async throws -> URL {
        if item.kind == .image {
            return fileURL(for: item)
        }
        if item.kind == .web {
            guard let rendered = renderedStillURL(for: item) else { throw ImportError.unreadable }
            return rendered
        }
        let stillURL = stillURL(for: item)
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

    // MARK: - Web wallpapers

    /// Copies a folder with a web page into the library. Wallpapers made for Wallpaper Engine
    /// bring their title and preview picture along.
    @discardableResult
    public func importWebProject(at folder: URL) throws -> Wallpaper {
        guard let source = WebProject(folder: folder) else {
            throw ImportError.noWebPage
        }
        let id = UUID()
        let destination = webURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: destination)
        if source.isScene {
            try SceneProject.refreshGeneratedFiles(in: destination)
        }

        var thumbnailFileName: String?
        if let preview = source.previewFile,
           let image = Thumbnailer.image(at: destination.appendingPathComponent(preview)) {
            thumbnailFileName = "\(id.uuidString).jpg"
            try? Thumbnailer.writeJPEG(image, to: thumbnailsURL.appendingPathComponent(thumbnailFileName!))
        }
        let item = Wallpaper(
            id: id,
            name: source.title ?? folder.lastPathComponent,
            kind: .web,
            fileName: "\(id.uuidString)/\(source.entryFile)",
            thumbnailFileName: thumbnailFileName,
            sourceFormat: source.isScene ? "SCENE" : "WEB",
            wasConverted: false,
            pixelWidth: 0,
            pixelHeight: 0,
            duration: nil,
            // Unknown until the page runs; assume it may make sound, so the sound settings apply.
            hasAudio: true,
            fileSize: Self.size(ofFolder: destination)
        )
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Makes a scene out of a video or picture of the library: a new wallpaper with that media as
    /// its background, ready for layers. The original stays as it is.
    @discardableResult
    public func makeScene(from original: Wallpaper, named name: String) throws -> Wallpaper {
        guard original.kind != .web else { throw ImportError.unreadable }
        let id = UUID()
        let folder = webURL.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = try SceneProject.addMedia(fileURL(for: original), to: folder, named: "background")
            let background = WallpaperScene.Background(kind: original.kind == .video ? .video : .image, source: source)
            try SceneProject.create(at: folder, scene: WallpaperScene(background: background))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }

        var thumbnailFileName: String?
        if let thumbnail = thumbnailURL(for: original) {
            thumbnailFileName = "\(id.uuidString).jpg"
            try? FileManager.default.copyItem(at: thumbnail, to: thumbnailsURL.appendingPathComponent(thumbnailFileName!))
        }
        let item = Wallpaper(
            id: id,
            name: name,
            kind: .web,
            fileName: "\(id.uuidString)/\(SceneProject.entryFileName)",
            thumbnailFileName: thumbnailFileName,
            sourceFormat: "SCENE",
            wasConverted: false,
            pixelWidth: original.pixelWidth,
            pixelHeight: original.pixelHeight,
            duration: original.duration,
            hasAudio: original.hasAudio,
            fileSize: Self.size(ofFolder: folder)
        )
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Whether the wallpaper is a scene the editor can open.
    public func isScene(_ item: Wallpaper) -> Bool {
        item.kind == .web && SceneProject.isScene(projectURL(for: item))
    }

    /// Stores a picture of the page as the library thumbnail. The app renders it, as only the app
    /// has a web view.
    public func setThumbnail(_ image: CGImage, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let fileName = "\(id.uuidString).jpg"
        guard (try? Thumbnailer.writeJPEG(image, to: thumbnailsURL.appendingPathComponent(fileName))) != nil else { return }
        // A new value even when the name is the same, so that views showing the picture refresh.
        items[index].thumbnailFileName = fileName
        items[index].fileSize = Self.size(ofFolder: projectURL(for: items[index]))
        save()
    }

    /// The still the app last rendered for a web wallpaper, if any.
    public func renderedStillURL(for item: Wallpaper) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stillsURL.path)) ?? []
        return names.first { $0.hasPrefix(item.id.uuidString) }.map(stillsURL.appendingPathComponent)
    }

    /// Stores a full-size picture of the page, for use as the regular macOS wallpaper. Every still
    /// gets a file name of its own: macOS does not look again at a desktop picture whose name it
    /// already knows, so an edited scene would keep its old picture on the lock screen.
    @discardableResult
    public func setStill(_ image: CGImage, for item: Wallpaper) throws -> URL {
        removeStill(for: item)
        let stamp = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let url = stillsURL.appendingPathComponent("\(item.id.uuidString)-\(stamp).jpg")
        try Thumbnailer.writeJPEG(image, to: url, quality: 0.92)
        return url
    }

    public func removeStill(for item: Wallpaper) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stillsURL.path)) ?? []
        for name in names where name.hasPrefix(item.id.uuidString) {
            try? FileManager.default.removeItem(at: stillsURL.appendingPathComponent(name))
        }
    }

    private static func size(ofFolder folder: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
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
            removeStill(for: item)
            var files = [item.kind == .web ? projectURL(for: item) : fileURL(for: item)]
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
