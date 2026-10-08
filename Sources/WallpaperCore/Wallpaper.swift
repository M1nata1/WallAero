import Foundation

/// A single entry of the wallpaper library.
public struct Wallpaper: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Played with AVFoundation. Animated images are converted to video on import.
        case video
        /// A still picture.
        case image
        /// A web page in a folder of its own: a scene made in the editor, or any page with an
        /// `index.html`. `fileName` is the page, relative to the library's web folder.
        case web
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    /// File name inside the library's media folder.
    public var fileName: String
    /// File name inside the library's thumbnail folder.
    public var thumbnailFileName: String?
    /// Short uppercase label of the original format, e.g. "GIF" or "MP4".
    public var sourceFormat: String
    /// Whether the original file was converted to video during import.
    public var wasConverted: Bool
    /// Size of the original media, in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Loop length in seconds; nil for still images.
    public var duration: Double?
    public var hasAudio: Bool
    /// Size of the stored media file, in bytes.
    public var fileSize: Int64
    public var dateAdded: Date

    public init(
        id: UUID,
        name: String,
        kind: Kind,
        fileName: String,
        thumbnailFileName: String?,
        sourceFormat: String,
        wasConverted: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double?,
        hasAudio: Bool,
        fileSize: Int64,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.sourceFormat = sourceFormat
        self.wasConverted = wasConverted
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.hasAudio = hasAudio
        self.fileSize = fileSize
        self.dateAdded = dateAdded
    }
}
