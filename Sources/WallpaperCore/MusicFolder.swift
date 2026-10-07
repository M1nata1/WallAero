import Foundation

/// The music found in a folder the user picked. Every subfolder with music in it is a playlist,
/// and so is every `.m3u` file; audio files lying directly in the folder belong to none.
public struct MusicFolder: Equatable, Sendable {
    public struct Playlist: Equatable, Identifiable, Sendable {
        public let name: String
        public let tracks: [URL]

        public var id: String { name }
    }

    public let url: URL
    public let playlists: [Playlist]
    /// Everything found, each file once: the loose files first, then playlist by playlist.
    public let allTracks: [URL]

    public var name: String { url.lastPathComponent }

    /// What AVFoundation plays. Ogg, Opus and WMA files are not on the list because it cannot.
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "m4b"]
    public static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    /// The tracks of one playlist, or all the music for nil or a playlist that no longer exists.
    public func tracks(inPlaylist name: String?) -> [URL] {
        playlists.first { $0.name == name }?.tracks ?? allTracks
    }

    public static func scan(_ url: URL) -> MusicFolder {
        let children = contents(of: url).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var loose: [URL] = []
        var playlists: [Playlist] = []
        for child in children {
            let fileExtension = child.pathExtension.lowercased()
            let name: String
            let tracks: [URL]
            if isDirectory(child) {
                name = child.lastPathComponent
                tracks = audioFiles(under: child)
            } else if playlistExtensions.contains(fileExtension) {
                name = child.deletingPathExtension().lastPathComponent
                tracks = tracksListed(in: child)
            } else {
                if audioExtensions.contains(fileExtension) {
                    loose.append(child)
                }
                continue
            }
            // A folder and a playlist file of the same name: the first one keeps the name.
            if !tracks.isEmpty, !playlists.contains(where: { $0.name == name }) {
                playlists.append(Playlist(name: name, tracks: tracks))
            }
        }

        var seen: Set<URL> = []
        let all = (loose + playlists.flatMap(\.tracks)).filter { seen.insert($0.standardizedFileURL).inserted }
        return MusicFolder(url: url, playlists: playlists, allTracks: all)
    }

    // MARK: - Finding files

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Every audio file below the folder, at any depth, in the order Finder lists them.
    private static func audioFiles(under folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var files: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            if audioExtensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The files an M3U playlist names, in its order: one path per line, relative to the playlist
    /// or absolute; lines starting with `#` are comments. Files that are missing are left out.
    private static func tracksListed(in playlist: URL) -> [URL] {
        guard let data = try? Data(contentsOf: playlist) else { return [] }
        // Older playlists are not UTF-8; Cyrillic ones are usually Windows-1251.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1251)
            ?? String(decoding: data, as: UTF8.self)
        let folder = playlist.deletingLastPathComponent()
        return text.components(separatedBy: .newlines).compactMap { line in
            let entry = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
            guard !entry.isEmpty, !entry.hasPrefix("#"), !entry.contains("://") else { return nil }
            let url = entry.hasPrefix("/") ? URL(fileURLWithPath: entry) : folder.appendingPathComponent(entry)
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return nil
            }
            return url.standardizedFileURL
        }
    }
}

/// The order tracks are played in: straight through and around again, or shuffled so that every
/// track plays once before any of them repeats.
public struct TrackQueue {
    public private(set) var tracks: [URL]
    public private(set) var shuffles: Bool
    private var order: [Int]
    private var position = 0

    /// - Parameter first: a track to begin with, such as the one playing when the list changed.
    public init(tracks: [URL] = [], shuffles: Bool = false, startingWith first: URL? = nil) {
        self.tracks = tracks
        self.shuffles = shuffles
        order = Array(tracks.indices)
        if shuffles {
            order.shuffle()
        }
        guard let first, let index = tracks.firstIndex(of: first) else { return }
        if shuffles {
            order.removeAll { $0 == index }
            order.insert(index, at: 0)
        } else {
            position = index
        }
    }

    public var current: URL? {
        order.indices.contains(position) ? tracks[order[position]] : nil
    }

    /// Moves to the next track and returns it. After the last one the list starts over, in a new
    /// order when shuffling, and never with the track that has just played.
    @discardableResult
    public mutating func advance() -> URL? {
        guard !tracks.isEmpty else { return nil }
        position += 1
        if position >= order.count {
            position = 0
            if shuffles, order.count > 1 {
                let last = order[order.count - 1]
                order.shuffle()
                if order[0] == last {
                    order.swapAt(0, Int.random(in: 1..<order.count))
                }
            }
        }
        return current
    }
}
