import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperCore

final class AnimatedImageConverterTests: XCTestCase {
    func testSmallAnimationsAreUpscaledByAnIntegerFactor() {
        let size = AnimatedImageConverter.outputSize(forWidth: 498, height: 280)
        XCTAssertEqual(size.width, 1494)
        XCTAssertEqual(size.height, 840)
        XCTAssertTrue(size.nearestNeighbor)
    }

    func testMediumAnimationsKeepTheirSizeButBecomeEven() {
        let size = AnimatedImageConverter.outputSize(forWidth: 1001, height: 563)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 562)
        XCTAssertFalse(size.nearestNeighbor)
    }

    func testHugeAnimationsAreScaledDown() {
        let size = AnimatedImageConverter.outputSize(forWidth: 5000, height: 5000)
        XCTAssertLessThanOrEqual(size.width * size.height, AnimatedImageConverter.maximumArea)
        XCTAssertEqual(size.width, size.height)
        XCTAssertEqual(size.width % 2, 0)
    }

    func testFramesWithoutDelayUseTheBrowserFallback() throws {
        let url = try TestMedia.directory().appendingPathComponent("delays.gif")
        try TestMedia.writeGIF(to: url, size: CGSize(width: 40, height: 30), delays: [0, 0.05, 0.2])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let delays = AnimatedImageConverter.frameDelays(of: source)
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(delays[1], 0.05, accuracy: 0.001)
        XCTAssertEqual(delays[2], 0.2, accuracy: 0.001)
        XCTAssertTrue(AnimatedImageConverter.isAnimated(source))
    }
}

@MainActor
final class WallpaperLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try TestMedia.directory()
    }

    func testImportingAGIFProducesAVideoOfTheSameLength() async throws {
        let gif = root.appendingPathComponent("Pixel Sunset.gif")
        try TestMedia.writeGIF(to: gif, size: CGSize(width: 320, height: 180), delays: Array(repeating: 0.1, count: 12))
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))

        let item = try await library.importFile(at: gif)

        XCTAssertEqual(item.name, "Pixel Sunset")
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.sourceFormat, "GIF")
        XCTAssertTrue(item.wasConverted)
        XCTAssertEqual(item.pixelWidth, 320)
        XCTAssertEqual(item.pixelHeight, 180)
        XCTAssertEqual(try XCTUnwrap(item.duration), 1.2, accuracy: 0.01)
        XCTAssertNotNil(library.thumbnailURL(for: item))

        let asset = AVURLAsset(url: library.fileURL(for: item))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.2, accuracy: 0.05)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let naturalSize = try await track.load(.naturalSize)
        // 320 px wide → enlarged 6× for crisp scaling.
        XCTAssertEqual(naturalSize, CGSize(width: 1920, height: 1080))
    }

    func testImportingAVideoCopiesItAndReadsItsMetadata() async throws {
        let movie = root.appendingPathComponent("Waves.mov")
        let gif = root.appendingPathComponent("source.gif")
        try TestMedia.writeGIF(to: gif, size: CGSize(width: 1280, height: 720), delays: Array(repeating: 0.04, count: 25))
        _ = try await AnimatedImageConverter.convert(source: gif, to: movie)
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))

        let item = try await library.importFile(at: movie)

        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.sourceFormat, "MOV")
        XCTAssertFalse(item.wasConverted)
        XCTAssertEqual(item.pixelWidth, 1280)
        XCTAssertEqual(item.pixelHeight, 720)
        XCTAssertEqual(try XCTUnwrap(item.duration), 1.0, accuracy: 0.05)
        XCTAssertFalse(item.hasAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: item).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path), "The original must stay where it was")
    }

    func testImportingAStillImageKeepsItAsAnImage() async throws {
        let png = root.appendingPathComponent("Mountains.png")
        try TestMedia.writePNG(to: png, size: CGSize(width: 800, height: 600))
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))

        let item = try await library.importFile(at: png)

        XCTAssertEqual(item.kind, .image)
        XCTAssertNil(item.duration)
        XCTAssertEqual(item.pixelWidth, 800)
        XCTAssertEqual(item.pixelHeight, 600)
        let still = try await library.stillImageURL(for: item)
        XCTAssertEqual(still, library.fileURL(for: item))
    }

    func testStillOfAVideoIsExtractedAtFullSize() async throws {
        let gif = root.appendingPathComponent("loop.gif")
        try TestMedia.writeGIF(to: gif, size: CGSize(width: 1200, height: 800), delays: [0.1, 0.1])
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))
        let item = try await library.importFile(at: gif)

        let still = try await library.stillImageURL(for: item)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(still as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1200)
    }

    func testUnsupportedFilesAreRejected() async throws {
        let text = root.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))

        do {
            try await library.importFile(at: text)
            XCTFail("Expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .unsupportedFormat("txt"))
        }
        XCTAssertTrue(library.items.isEmpty)
    }

    func testBrokenVideosAreRejected() async throws {
        let fake = root.appendingPathComponent("broken.mp4")
        try Data(repeating: 7, count: 4096).write(to: fake)
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))

        do {
            try await library.importFile(at: fake)
            XCTFail("Expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .undecodableVideo)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.mediaURL.path)
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAWebFolderIsImportedWholeAndRemovedWhole() async throws {
        let source = try TestMedia.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let folder = source.appendingPathComponent("Neon")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        try "<html></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent("js/app.js"), atomically: true, encoding: .utf8)

        let library = WallpaperLibrary(rootURL: root)
        let item = try library.importWebProject(at: folder)

        XCTAssertEqual(item.kind, .web)
        XCTAssertEqual(item.name, "Neon")
        XCTAssertEqual(item.sourceFormat, "WEB")
        XCTAssertEqual(library.fileURL(for: item).lastPathComponent, "index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.projectURL(for: item).appendingPathComponent("js/app.js").path))
        XCTAssertFalse(library.isScene(item))
        XCTAssertEqual(WallpaperLibrary(rootURL: root).items.map(\.id), [item.id], "survives a restart")
        XCTAssertThrowsError(try library.importWebProject(at: source), "a folder without a page") { error in
            XCTAssertEqual(error as? ImportError, .noWebPage)
        }

        library.remove([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.projectURL(for: item).path))
    }

    func testAVideoBecomesASceneWithItselfAsTheBackground() async throws {
        let videoURL = root.appendingPathComponent("source.gif")
        try TestMedia.writeGIF(to: videoURL, size: CGSize(width: 64, height: 36), delays: [0.1, 0.1, 0.1])
        let library = WallpaperLibrary(rootURL: root.appendingPathComponent("library"))
        let video = try await library.importFile(at: videoURL)

        let scene = try library.makeScene(from: video, named: "Editable")

        XCTAssertEqual(scene.kind, .web)
        XCTAssertEqual(scene.name, "Editable")
        XCTAssertEqual(scene.sourceFormat, "SCENE")
        XCTAssertTrue(library.isScene(scene))
        XCTAssertEqual(library.items.map(\.id), [scene.id, video.id], "the original stays")
        let stored = try SceneProject.read(from: library.projectURL(for: scene))
        XCTAssertEqual(stored.background.kind, .video)
        XCTAssertEqual(stored.background.source, "media/background.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.projectURL(for: scene).appendingPathComponent("media/background.mov").path))
        XCTAssertNotNil(library.thumbnailURL(for: scene), "starts with the original's thumbnail")
        XCTAssertThrowsError(try library.makeScene(from: scene, named: "Again"), "a scene is edited, not wrapped again")
    }

    func testWebStillsGetANewFileNameEachTime() async throws {
        let library = WallpaperLibrary(rootURL: root)
        let folder = root.appendingPathComponent("page")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<html></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try library.importWebProject(at: folder)
        let picture = try XCTUnwrap(Thumbnailer.image(at: try TestMedia.pngFile(in: root)))

        XCTAssertNil(library.renderedStillURL(for: item))
        let first = try library.setStill(picture, for: item)
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = try library.setStill(picture, for: item)

        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent, "macOS ignores a changed picture under a known name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the old still does not pile up")
        let stillURL = try await library.stillImageURL(for: item)
        XCTAssertEqual(stillURL, second)
        library.remove([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testEveryWallpaperHasSettingsOfItsOwn() async throws {
        let folder = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(rootURL: folder)
        let first = try await library.importFile(at: TestMedia.pngFile(in: root))
        let second = try await library.importFile(at: TestMedia.pngFile(in: root))
        XCTAssertNil(first.settings)
        XCTAssertEqual(first.shownSettings, Wallpaper.Settings(scaling: .fill, position: 50, speed: 1))

        library.setSettings(Wallpaper.Settings(scaling: .fit, position: 20, speed: 0.5), for: first.id)
        // What used to be one setting for all goes to those that have none of their own.
        library.adoptSettings { _ in Wallpaper.Settings(scaling: .stretch) }

        let reopened = WallpaperLibrary(rootURL: folder)
        XCTAssertEqual(reopened.item(withID: first.id)?.shownSettings, Wallpaper.Settings(scaling: .fit, position: 20, speed: 0.5))
        XCTAssertEqual(reopened.item(withID: second.id)?.shownSettings.scaling, .stretch)
    }

    func testALibraryWrittenBeforeSettingsExistedStillOpens() throws {
        let old = #"[{"dateAdded":"2026-10-01T09:00:00Z","duration":6.8,"fileName":"a.mp4","fileSize":10,"hasAudio":true,"id":"09970F42-E5A6-40F3-8100-68207CA21CDF","kind":"video","name":"Old","pixelHeight":1080,"pixelWidth":1920,"sourceFormat":"MP4","thumbnailFileName":null,"wasConverted":false}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try XCTUnwrap(decoder.decode([Wallpaper].self, from: Data(old.utf8)).first)
        XCTAssertEqual(item.name, "Old")
        XCTAssertNil(item.settings)
        XCTAssertEqual(item.shownSettings.speed, 1)
        XCTAssertEqual(item.tagList, [])
    }

    func testTagsAreTidiedKeptAndListed() async throws {
        let folder = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(rootURL: folder)
        let first = try await library.importFile(at: TestMedia.pngFile(in: root))
        let second = try await library.importFile(at: TestMedia.pngFile(in: root))
        XCTAssertNil(first.tags)
        XCTAssertTrue(library.allTags.isEmpty)

        library.setTags(["  Night ", "", "anime", "night"], for: first.id)
        XCTAssertEqual(library.item(withID: first.id)?.tagList, ["Night", "anime"])
        // The spelling in use wins, so one tag is not two filters.
        library.setTags(["ANIME", "City"], for: second.id)
        XCTAssertEqual(library.item(withID: second.id)?.tagList, ["anime", "City"])
        XCTAssertEqual(library.allTags, ["anime", "City", "Night"])

        let reopened = WallpaperLibrary(rootURL: folder)
        XCTAssertEqual(reopened.item(withID: first.id)?.tagList, ["Night", "anime"])
        reopened.setTags([], for: first.id)
        XCTAssertNil(reopened.item(withID: first.id)?.tags)
        XCTAssertEqual(reopened.allTags, ["anime", "City"])
    }

    func testTagsAreGroupedByTheirCategories() async throws {
        let folder = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(rootURL: folder)
        let first = try await library.importFile(at: TestMedia.pngFile(in: root))
        let second = try await library.importFile(at: TestMedia.pngFile(in: root))
        library.setTags(["Anime", "Calm", "4K"], for: first.id)
        library.setTags(["Nature"], for: second.id)
        XCTAssertEqual(library.tagGroups, [TagGroup(category: nil, tags: ["4K", "Anime", "Calm", "Nature"])])

        library.setCategory(" Genre ", ofTag: "Anime")
        library.setCategory("genre", ofTag: "nature")
        library.setCategory("Mood", ofTag: "Calm")
        XCTAssertEqual(library.category(of: "ANIME"), "Genre")
        XCTAssertEqual(library.allCategories, ["Genre", "Mood"])
        XCTAssertEqual(library.tagGroups, [
            TagGroup(category: "Genre", tags: ["Anime", "Nature"]),
            TagGroup(category: "Mood", tags: ["Calm"]),
            TagGroup(category: nil, tags: ["4K"]),
        ])

        // The categories are kept apart from the wallpapers, in a file of their own.
        let reopened = WallpaperLibrary(rootURL: folder)
        XCTAssertEqual(reopened.category(of: "Nature"), "Genre")
        reopened.setCategory(nil, ofTag: "Calm")
        XCTAssertEqual(WallpaperLibrary(rootURL: folder).allCategories, ["Genre"])
        // A category lives as long as a wallpaper has one of its tags.
        reopened.setTags([], for: first.id)
        reopened.setTags([], for: second.id)
        XCTAssertTrue(reopened.tagGroups.isEmpty)
    }

    func testSearchLooksInNamesAndTagsAndTheFilterTakesAnyTagOfEachGroup() {
        func wallpaper(_ name: String, _ tags: [String]?) -> Wallpaper {
            Wallpaper(id: UUID(), name: name, kind: .video, fileName: "a.mp4", thumbnailFileName: nil, sourceFormat: "MP4",
                      wasConverted: false, pixelWidth: 1920, pixelHeight: 1080, duration: 5, hasAudio: false, fileSize: 1, tags: tags)
        }
        let lake = wallpaper("Japan Lake", ["Nature", "Night"])
        let frogs = wallpaper("Лягушки", ["Nature"])
        let plain = wallpaper("Steins Gate", nil)

        XCTAssertTrue(plain.matches(search: ""))
        XCTAssertTrue(plain.matches(search: "  "))
        XCTAssertTrue(lake.matches(search: "lake"))
        XCTAssertTrue(frogs.matches(search: "лягуш"))
        XCTAssertFalse(frogs.matches(search: "lake"))
        // A tag is found by the search as well as a name.
        XCTAssertTrue(frogs.matches(search: "natu"))
        XCTAssertFalse(plain.matches(search: "natu"))

        // Ticked tags of one category: any of them will do.
        XCTAssertTrue(frogs.matches(search: "", tagGroups: [["nature", "Anime"]]))
        XCTAssertFalse(plain.matches(search: "", tagGroups: [["Nature", "Anime"]]))
        // Tags of two categories: one of each is needed.
        XCTAssertTrue(lake.matches(search: "", tagGroups: [["Nature"], ["Night", "Day"]]))
        XCTAssertFalse(frogs.matches(search: "", tagGroups: [["Nature"], ["Night", "Day"]]))
        XCTAssertTrue(plain.matches(search: "", tagGroups: [[]]))
        XCTAssertFalse(lake.matches(search: "frog", tagGroups: [["Nature"]]))
    }

    func testLibraryIsPersistedRenamedAndCleanedUp() async throws {
        let png = root.appendingPathComponent("Calm.png")
        try TestMedia.writePNG(to: png, size: CGSize(width: 64, height: 64))
        let libraryRoot = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(rootURL: libraryRoot)
        let item = try await library.importFile(at: png)
        library.rename(item.id, to: "  Quiet lake ")

        let reopened = WallpaperLibrary(rootURL: libraryRoot)
        XCTAssertEqual(reopened.items.map(\.name), ["Quiet lake"])

        let mediaFile = reopened.fileURL(for: item)
        let thumbnail = try XCTUnwrap(reopened.thumbnailURL(for: item))
        reopened.remove([item.id])
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertTrue(WallpaperLibrary(rootURL: libraryRoot).items.isEmpty)
    }
}

final class LegacyDataTests: XCTestCase {
    private var base: URL!
    private var old: URL { base.appendingPathComponent("AiWallpaper") }
    private var new: URL { base.appendingPathComponent("WallAeroEngine") }

    override func setUpWithError() throws {
        base = try TestMedia.directory()
        addTeardownBlock { [base] in try? FileManager.default.removeItem(at: base!) }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func text(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func testAnUntouchedInstallJustGetsItsFolderRenamed() throws {
        try write("library", to: old.appendingPathComponent("library.json"))
        try write("video", to: old.appendingPathComponent("Media/a.mov"))

        LegacyData.moveContents(of: old, into: new)

        XCTAssertEqual(text(at: new.appendingPathComponent("library.json")), "library")
        XCTAssertEqual(text(at: new.appendingPathComponent("Media/a.mov")), "video")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testOldDataMergesIntoFoldersTheNewAppAlreadyCreated() throws {
        try write("library", to: old.appendingPathComponent("library.json"))
        try write("video", to: old.appendingPathComponent("Media/a.mov"))
        try write("backup", to: old.appendingPathComponent("CursorBackup/arrow.json"))
        // The new app (or cursorctl) has been there first: empty folders and a file of its own.
        try FileManager.default.createDirectory(at: new.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try write("newer", to: new.appendingPathComponent("CursorBackup/ibeam.json"))

        LegacyData.moveContents(of: old, into: new)

        XCTAssertEqual(text(at: new.appendingPathComponent("library.json")), "library")
        XCTAssertEqual(text(at: new.appendingPathComponent("Media/a.mov")), "video")
        XCTAssertEqual(text(at: new.appendingPathComponent("CursorBackup/arrow.json")), "backup")
        XCTAssertEqual(text(at: new.appendingPathComponent("CursorBackup/ibeam.json")), "newer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testNothingInTheNewFolderIsOverwritten() throws {
        try write("old library", to: old.appendingPathComponent("library.json"))
        try write("new library", to: new.appendingPathComponent("library.json"))

        LegacyData.moveContents(of: old, into: new)

        XCTAssertEqual(text(at: new.appendingPathComponent("library.json")), "new library")
        XCTAssertEqual(text(at: old.appendingPathComponent("library.json")), "old library", "the old file is left, not deleted")
    }

    func testDoesNothingWithoutAnOldFolder() {
        LegacyData.moveContents(of: old, into: new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }
}

final class MusicFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestMedia.directory()
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    private func touch(_ path: String, _ text: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func names(_ tracks: [URL]) -> [String] {
        tracks.map(\.lastPathComponent)
    }

    func testSubfoldersBecomePlaylistsAndLooseFilesBelongToNone() throws {
        try touch("intro.mp3")
        try touch("cover.jpg")
        try touch(".hidden.mp3")
        try touch("Rock/2 second.flac")
        try touch("Rock/10 tenth.mp3")
        try touch("Rock/1 first.m4a")
        try touch("Rock/Live/encore.wav")
        try touch("Rock/notes.txt")
        try touch("Calm/rain.aiff")
        try touch("Empty/readme.txt")

        let folder = MusicFolder.scan(root)

        XCTAssertEqual(folder.playlists.map(\.name), ["Calm", "Rock"], "a folder without music is not a playlist")
        // Numbers sort the way Finder shows them, and nested folders are part of the playlist.
        XCTAssertEqual(names(folder.tracks(inPlaylist: "Rock")), ["1 first.m4a", "2 second.flac", "10 tenth.mp3", "encore.wav"])
        XCTAssertEqual(names(folder.allTracks), ["intro.mp3", "rain.aiff", "1 first.m4a", "2 second.flac", "10 tenth.mp3", "encore.wav"])
        XCTAssertEqual(folder.tracks(inPlaylist: nil), folder.allTracks)
        XCTAssertEqual(folder.tracks(inPlaylist: "Deleted"), folder.allTracks, "a playlist that is gone falls back to everything")
    }

    func testM3UFilesArePlaylistsInTheirOwnOrder() throws {
        try touch("Songs/b.mp3")
        try touch("Songs/a.mp3")
        try touch("Songs/c.mp3")
        try touch("Favourites.m3u", "#EXTM3U\n#EXTINF:123,Artist - C\nSongs/c.mp3\r\nSongs\\a.mp3\nSongs/missing.mp3\nhttp://example.com/stream.mp3\n\n")

        let folder = MusicFolder.scan(root)

        XCTAssertEqual(folder.playlists.map(\.name), ["Favourites", "Songs"])
        XCTAssertEqual(names(folder.tracks(inPlaylist: "Favourites")), ["c.mp3", "a.mp3"], "playlist order, missing files and streams left out")
        XCTAssertEqual(names(folder.allTracks).sorted(), ["a.mp3", "b.mp3", "c.mp3"], "a file in two playlists is listed once")
    }

    func testAFolderWithoutMusicHasNoTracks() throws {
        try touch("picture.png")
        XCTAssertTrue(MusicFolder.scan(root).allTracks.isEmpty)
        XCTAssertTrue(MusicFolder.scan(root.appendingPathComponent("no such folder")).allTracks.isEmpty)
    }
}

final class TrackQueueTests: XCTestCase {
    private let tracks = (1...5).map { URL(fileURLWithPath: "/music/\($0).mp3") }

    func testPlaysInOrderAndStartsOver() {
        var queue = TrackQueue(tracks: tracks, shuffles: false)
        var played = [queue.current]
        for _ in 0..<6 { played.append(queue.advance()) }
        XCTAssertEqual(played, tracks + [tracks[0], tracks[1]])
    }

    func testCanStartWithTheTrackThatIsPlaying() {
        var queue = TrackQueue(tracks: tracks, shuffles: false, startingWith: tracks[3])
        XCTAssertEqual(queue.current, tracks[3])
        XCTAssertEqual(queue.advance(), tracks[4])
        XCTAssertEqual(queue.advance(), tracks[0])
        XCTAssertEqual(TrackQueue(tracks: tracks, shuffles: true, startingWith: tracks[3]).current, tracks[3])
    }

    func testShufflePlaysEveryTrackOnceBeforeRepeating() {
        for _ in 0..<50 {
            var queue = TrackQueue(tracks: tracks, shuffles: true)
            var played = [queue.current!]
            for _ in 0..<14 { played.append(queue.advance()!) }
            for pass in stride(from: 0, to: 15, by: 5) {
                XCTAssertEqual(Set(played[pass..<pass + 5]), Set(tracks))
            }
            for index in 1..<played.count {
                XCTAssertNotEqual(played[index], played[index - 1], "never the same track twice in a row")
            }
        }
    }

    func testAnEmptyQueueHasNothingToPlay() {
        var queue = TrackQueue()
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.advance())
    }
}

@MainActor
final class PlaylistPlayerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try TestMedia.directory()
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    /// Waits until the player reports each of the tracks in turn.
    private func expect(_ player: PlaylistPlayer, toPlay tracks: [URL], file: StaticString = #filePath, line: UInt = #line) async {
        for track in tracks {
            let deadline = Date().addingTimeInterval(5)
            while player.currentTrack != track, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(player.currentTrack?.lastPathComponent, track.lastPathComponent, file: file, line: line)
        }
    }

    func testPlaysTheListAroundAndSkipsFilesItCannotOpen() async throws {
        let first = root.appendingPathComponent("1.wav")
        let broken = root.appendingPathComponent("2.mp3")
        let last = root.appendingPathComponent("3.wav")
        try TestMedia.writeSilentWAV(to: first, seconds: 0.3)
        try Data("not audio".utf8).write(to: broken)
        try TestMedia.writeSilentWAV(to: last, seconds: 0.3)

        let player = PlaylistPlayer()
        player.volume = 0
        XCTAssertFalse(player.hasTracks)
        player.setTracks([first, broken, last], shuffled: false)
        XCTAssertTrue(player.hasTracks)
        XCTAssertEqual(player.currentTrack, first, "known before playback starts")

        player.setPlaying(true)
        await expect(player, toPlay: [last, first, last])
        player.setPlaying(false)
    }

    func testSkippingAndChangingTheList() async throws {
        let urls = try (1...3).map { index -> URL in
            let url = root.appendingPathComponent("\(index).wav")
            try TestMedia.writeSilentWAV(to: url, seconds: 5)
            return url
        }
        let player = PlaylistPlayer()
        player.volume = 0
        player.setTracks(urls, shuffled: false)
        player.skipToNext()
        XCTAssertEqual(player.currentTrack, urls[1])

        // The track that is playing stays when it is on the new list too…
        player.setTracks([urls[1], urls[2]], shuffled: false)
        XCTAssertEqual(player.currentTrack, urls[1])
        // …and gives way to the new list when it is not.
        player.setTracks([urls[0]], shuffled: false)
        XCTAssertEqual(player.currentTrack, urls[0])
        player.setTracks([], shuffled: false)
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.hasTracks)
    }
}

final class WallpaperSceneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestMedia.directory()
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    func testASceneSurvivesBeingWrittenAndReadBack() throws {
        var clock = WallpaperScene.Layer(kind: .text, name: "Clock")
        clock.text = "{HH}:{mm}"
        clock.x = 25
        clock.fontSize = 14
        var logo = WallpaperScene.Layer(kind: .image, name: "Logo")
        logo.source = "media/logo.png"
        let scene = WallpaperScene(
            background: .init(kind: .video, source: "media/background.mp4", fit: .contain, blur: 8, brightness: 70),
            layers: [clock, logo]
        )
        try SceneProject.create(at: root, scene: scene)

        XCTAssertEqual(try SceneProject.read(from: root), scene)
        XCTAssertTrue(SceneProject.isScene(root))
        for file in ["index.html", "runtime.js", "custom.css", "custom.js", "scene.json", "media"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), file)
        }
    }

    func testMissingAndWrongValuesFallBackToDefaults() throws {
        // As a person might write it by hand: few keys, one of them of the wrong type.
        let json = #"{"background": {"kind": "image", "source": "a.png", "blur": "lots"}, "layers": [{"kind": "text", "text": "Hi", "x": 10}]}"#
        let scene = try JSONDecoder().decode(WallpaperScene.self, from: Data(json.utf8))

        XCTAssertEqual(scene.version, WallpaperScene.currentVersion)
        XCTAssertEqual(scene.background.kind, .image)
        XCTAssertEqual(scene.background.blur, 0)
        XCTAssertEqual(scene.background.brightness, 100)
        XCTAssertEqual(scene.layers.count, 1)
        XCTAssertEqual(scene.layers[0].text, "Hi")
        XCTAssertEqual(scene.layers[0].x, 10)
        XCTAssertEqual(scene.layers[0].y, 50)
        XCTAssertEqual(scene.layers[0].opacity, 100)
        XCTAssertTrue(scene.layers[0].isVisible)
        XCTAssertTrue(scene.layers[0].showsOnLockScreen, "scenes saved before the setting existed keep showing everything")
    }

    func testALayerCanBeLeftOutOfTheLockScreenPicture() throws {
        var clock = WallpaperScene.Layer(kind: .text, name: "Clock")
        XCTAssertTrue(clock.showsOnLockScreen)
        clock.showsOnLockScreen = false
        try SceneProject.create(at: root, scene: WallpaperScene(layers: [clock]))

        XCTAssertFalse(try SceneProject.read(from: root).layers[0].showsOnLockScreen)
        let text = try String(contentsOf: root.appendingPathComponent("scene.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"showsOnLockScreen\" : false"))
        // The page has to act on it, or the setting would do nothing.
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("runtime.js"), encoding: .utf8).contains("showsOnLockScreen"))
    }

    func testVariablesSurviveBeingWrittenAndFillInWhatIsMissing() throws {
        var color = WallpaperScene.Variable(kind: .color, title: "Цвет полос", key: "bars")
        color.color = "#FFAA00"
        var count = WallpaperScene.Variable(kind: .number, title: "Bars", key: "count")
        count.number = 22
        count.maximum = 64
        let scene = WallpaperScene(variables: [color, count])
        try SceneProject.write(scene, to: root)
        XCTAssertEqual(try SceneProject.read(from: root).variables, [color, count])

        // Written by hand: only what matters is there, and the key is not fit for code.
        let json = #"{"variables": [{"kind": "toggle", "key": "show clock"}, {"kind": "nonsense"}, {"title": "no kind"}]}"#
        try json.write(to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try SceneProject.read(from: root).variables, [], "one bad variable loses them all, but not the scene")

        let good = #"{"variables": [{"kind": "toggle", "key": "show clock"}]}"#
        try good.write(to: root.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(SceneProject.read(from: root).variables.first)
        XCTAssertEqual(read.key, "show_clock")
        XCTAssertEqual(read.title, "show_clock")
        XCTAssertTrue(read.isOn)
    }

    func testVariableKeysAreFitForCodeAndUnique() {
        XCTAssertEqual(WallpaperScene.Variable.key(from: "цвет полос"), "cvet_polos")
        XCTAssertEqual(WallpaperScene.Variable.key(from: "Цвет"), "Cvet", "capitals are kept")
        XCTAssertEqual(WallpaperScene.Variable.key(from: "bar-count!"), "bar_count")
        XCTAssertEqual(WallpaperScene.Variable.key(from: "2 colors"), "_2_colors")
        XCTAssertEqual(WallpaperScene.Variable.key(from: "  "), "variable")
        XCTAssertEqual(WallpaperScene.Variable.key(from: "barCount"), "barCount")

        let first = WallpaperScene.Variable(kind: .color, title: "Color", key: "color")
        let scene = WallpaperScene(variables: [first])
        XCTAssertEqual(scene.uniqueKey("Color"), "Color", "keys tell capitals apart, as code does")
        XCTAssertEqual(scene.uniqueKey("color"), "color2")
        XCTAssertEqual(scene.uniqueKey("color", for: first.id), "color", "a variable does not clash with itself")
    }

    func testStoringValuesLeavesTheRestOfTheSceneAlone() throws {
        var speed = WallpaperScene.Variable(kind: .number, title: "Speed", key: "speed")
        speed.number = 1
        let label = WallpaperScene.Variable(kind: .text, title: "Label", key: "label")
        try SceneProject.write(WallpaperScene(layers: [.init(kind: .text, name: "Clock")], variables: [speed, label]), to: root)

        // Meanwhile the scene is edited: a layer is added, a variable renamed, another removed.
        var edited = try SceneProject.read(from: root)
        edited.layers.append(.init(kind: .shape, name: "Box"))
        edited.variables[0].title = "Tempo"
        edited.variables.remove(at: 1)
        try SceneProject.write(edited, to: root)

        // The settings still hold the scene as it was, with new values.
        var fromSettings = speed
        fromSettings.number = 3
        var gone = label
        gone.text = "hello"
        let stored = try SceneProject.storeValues(of: [fromSettings, gone], in: root)

        XCTAssertEqual(stored.layers.map(\.name), ["Clock", "Box"])
        XCTAssertEqual(stored.variables.map(\.title), ["Tempo"])
        XCTAssertEqual(stored.variables[0].number, 3)
        XCTAssertEqual(try SceneProject.read(from: root), stored)

        // How the background fills the screen is stored only when it is given.
        XCTAssertEqual(stored.background.fit, .cover)
        let framed = try SceneProject.storeValues(of: [], framing: (fit: .contain, position: 80), in: root)
        XCTAssertEqual(framed.background.fit, .contain)
        XCTAssertEqual(framed.background.position, 80)
        XCTAssertEqual(framed.variables[0].number, 3, "the variables stay as they were")
        XCTAssertEqual(try SceneProject.storeValues(of: [], in: root).background.position, 80)
    }

    func testGeneratedFilesAreRefreshedButCustomOnesAreKept() throws {
        try SceneProject.create(at: root, scene: WallpaperScene())
        XCTAssertFalse(try SceneProject.refreshGeneratedFiles(in: root), "nothing to do right after creating")

        // An older version of the app left an old runtime; the user has written their own script.
        try "old".write(to: root.appendingPathComponent("runtime.js"), atomically: true, encoding: .utf8)
        try "mine".write(to: root.appendingPathComponent("custom.js"), atomically: true, encoding: .utf8)

        XCTAssertTrue(try SceneProject.refreshGeneratedFiles(in: root))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("runtime.js"), encoding: .utf8).contains("wallaero"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("custom.js"), encoding: .utf8), "mine")
    }

    func testMediaIsCopiedUnderAPlainUniqueName() throws {
        let picture = root.appendingPathComponent("Моя картинка #1.PNG")
        try TestMedia.writePNG(to: picture, size: CGSize(width: 8, height: 8))
        let project = root.appendingPathComponent("project")

        let first = try SceneProject.addMedia(picture, to: project)
        let second = try SceneProject.addMedia(picture, to: project)
        let named = try SceneProject.addMedia(picture, to: project, named: "background")

        XCTAssertEqual(first, "media/1.png", "only plain characters survive, as the name goes into a URL")
        XCTAssertEqual(second, "media/1-2.png")
        XCTAssertEqual(named, "media/background.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent(second).path))
    }
}

final class WebProjectTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestMedia.directory()
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testAFolderWithAnIndexPageIsAWebWallpaper() throws {
        try write("<html></html>", to: "index.html")
        try write("<html></html>", to: "about.html")
        let project = try XCTUnwrap(WebProject(folder: root))
        XCTAssertEqual(project.entryFile, "index.html")
        XCTAssertNil(project.title)
        XCTAssertNil(project.userPropertiesJSON)
        XCTAssertFalse(project.isScene)
    }

    func testReadsAWallpaperEngineProject() throws {
        try write("<html></html>", to: "main.html")
        try TestMedia.writePNG(to: root.appendingPathComponent("preview.png"), size: CGSize(width: 8, height: 8))
        try write(#"{"file": "main.html", "type": "web", "title": "Neon Rain", "preview": "preview.png", "general": {"properties": {"speed": {"type": "slider", "value": 3}}}}"#, to: "project.json")

        let project = try XCTUnwrap(WebProject(folder: root))
        XCTAssertEqual(project.entryFile, "main.html")
        XCTAssertEqual(project.title, "Neon Rain")
        XCTAssertEqual(project.previewFile, "preview.png")
        XCTAssertEqual(project.userPropertiesJSON, #"{"speed":{"type":"slider","value":3}}"#)
    }

    func testOtherKindsOfWallpaperEngineProjectsAndEmptyFoldersAreNotWebWallpapers() throws {
        XCTAssertNil(WebProject(folder: root), "no page at all")
        try write("<html></html>", to: "a.html")
        try write("<html></html>", to: "b.html")
        XCTAssertNil(WebProject(folder: root), "two pages and neither is index.html: which one?")
        try write("<html></html>", to: "index.html")
        try write(#"{"file": "scene.pkg", "type": "scene"}"#, to: "project.json")
        XCTAssertNil(WebProject(folder: root), "a Wallpaper Engine scene is not a page")
    }

    func testASceneIsRecognisedBeforeItsPageIsGenerated() throws {
        try write("{}", to: "scene.json")
        let project = try XCTUnwrap(WebProject(folder: root))
        XCTAssertTrue(project.isScene)
        XCTAssertEqual(project.entryFile, "index.html")
    }
}

final class SpectrumAnalyzerTests: XCTestCase {
    private let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
    private let frame = 1.0 / 30

    private func tone(_ frequency: Double, volume: Float = 0.5) -> [Float] {
        (0..<analyzer.windowSize).map { volume * Float(sin(2 * Double.pi * frequency * Double($0) / analyzer.sampleRate)) }
    }

    private var quiet: [Float] { [Float](repeating: 0, count: analyzer.windowSize) }

    /// The band whose centre is nearest to a frequency.
    private func band(for frequency: Double) -> Int {
        (0..<SpectrumAnalyzer.bandCount).min { abs(log(analyzer.frequency(ofBand: $0) / frequency)) < abs(log(analyzer.frequency(ofBand: $1) / frequency)) }!
    }

    func testBandsRunFromLowNotesToHighOnes() {
        let frequencies = (0..<SpectrumAnalyzer.bandCount).map(analyzer.frequency(ofBand:))
        XCTAssertEqual(frequencies, frequencies.sorted())
        XCTAssertLessThan(frequencies[0], 50)
        XCTAssertGreaterThan(frequencies[63], 12_000)
    }

    func testAToneLightsItsOwnBandAndLeavesTheRestDark() {
        let levels = analyzer.levels(left: tone(1000), right: tone(1000), interval: frame)
        XCTAssertEqual(levels.count, 2 * SpectrumAnalyzer.bandCount)
        let lit = band(for: 1000)
        XCTAssertEqual(levels[lit], 1, accuracy: 0.05)
        XCTAssertEqual(levels[lit + 64], 1, accuracy: 0.05, "the right channel follows the left's bands")
        for index in 0..<SpectrumAnalyzer.bandCount where abs(index - lit) > 6 {
            XCTAssertEqual(levels[index], 0, "band \(index) is far from the tone")
        }
    }

    func testLowAndHighTonesLandAtOppositeEnds() {
        let low = analyzer.levels(left: tone(60), right: tone(60), interval: frame)
        XCTAssertLessThan(low.firstIndex(of: low.max()!)!, 8)
        let other = SpectrumAnalyzer(sampleRate: 48_000)
        let high = other.levels(left: tone(10_000), right: tone(10_000), interval: frame)
        XCTAssertGreaterThan(high[..<64].firstIndex(of: high[..<64].max()!)!, 54)
    }

    func testChannelsAreKeptApart() {
        let levels = analyzer.levels(left: tone(1000), right: quiet, interval: frame)
        XCTAssertGreaterThan(levels[..<64].max()!, 0.9)
        XCTAssertEqual(levels[64...].max()!, 0)
    }

    func testAQuietSourceFillsTheBarsLikeALoudOne() {
        let loud = analyzer.levels(left: tone(1000, volume: 0.5), right: quiet, interval: frame)
        let other = SpectrumAnalyzer(sampleRate: 48_000)
        let soft = other.levels(left: tone(1000, volume: 0.02), right: quiet, interval: frame)
        XCTAssertEqual(soft.max()!, loud.max()!, accuracy: 0.01)
    }

    func testHissIsNotBlownUpIntoMusic() {
        let levels = analyzer.levels(left: tone(1000, volume: 0.000_05), right: quiet, interval: frame)
        XCTAssertLessThan(levels.max()!, 0.3)
    }

    func testLevelsFallAwayGraduallyInSilence() {
        _ = analyzer.levels(left: tone(1000), right: tone(1000), interval: frame)
        let lit = band(for: 1000)
        let afterOneFrame = analyzer.silence(interval: frame)[lit]
        XCTAssertGreaterThan(afterOneFrame, 0.8, "a bar does not drop to the floor at once")
        XCTAssertLessThan(afterOneFrame, 1)
        var levels: [Float] = []
        for _ in 0..<30 {
            levels = analyzer.silence(interval: frame)
        }
        XCTAssertEqual(levels.max()!, 0, "a second of silence leaves every bar down")
    }

    func testOtherSampleRatesKeepTheSameBands() {
        let other = SpectrumAnalyzer(sampleRate: 44_100)
        XCTAssertEqual(other.frequency(ofBand: 20), analyzer.frequency(ofBand: 20), accuracy: 0.01)
        let samples = (0..<other.windowSize).map { 0.5 * Float(sin(2 * Double.pi * 1000 * Double($0) / 44_100)) }
        let levels = other.levels(left: samples, right: samples, interval: frame)
        XCTAssertEqual(levels.firstIndex(of: levels.max()!)!, band(for: 1000), accuracy: 1)
    }
}

// MARK: - Helpers

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped)
}

enum TestMedia {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallAeroEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short mono WAV of silence: enough for a player to open, play through and finish.
    static func writeSilentWAV(to url: URL, seconds: Double) throws {
        let sampleRate: UInt32 = 8000
        let dataSize = UInt32(Double(sampleRate) * seconds) * 2
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(36 + dataSize)
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(sampleRate); append(sampleRate * 2)                 // byte rate
        append(UInt16(2)); append(UInt16(16))                      // block align, bits per sample
        wav.append(Data("data".utf8))
        append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        try wav.write(to: url)
    }

    static func writeGIF(to url: URL, size: CGSize, delays: [Double]) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)
        )
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        for (index, delay) in delays.enumerated() {
            let frame = try image(size: size, hue: Double(index) / Double(delays.count))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, frame, properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A small PNG written into the folder; returns where it is.
    static func pngFile(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("picture-\(UUID().uuidString).png")
        try writePNG(to: url, size: CGSize(width: 16, height: 9))
        return url
    }

    static func writePNG(to url: URL, size: CGSize) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, try image(size: size, hue: 0.6), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func image(size: CGSize, hue: Double) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: size.width * hue, y: 0, width: size.width / 10, height: size.height))
        return try XCTUnwrap(context.makeImage())
    }
}
