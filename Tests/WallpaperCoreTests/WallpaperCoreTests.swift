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
