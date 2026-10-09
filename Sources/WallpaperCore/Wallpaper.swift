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
    /// How this wallpaper is shown, once that has been set; `shownSettings` is what to go by.
    public var settings: Settings?

    /// What every wallpaper lets be set: how it fills the screen and how fast it plays.
    public struct Settings: Codable, Hashable, Sendable {
        public enum Scaling: String, Codable, CaseIterable, Sendable {
            /// Covers the whole screen, cropping the edges if the proportions differ.
            case fill
            /// Shows the whole picture, with black bars.
            case fit
            case stretch
        }

        public var scaling: Scaling
        /// Which part stays in view when filling the screen crops the picture, in percent:
        /// 0 keeps the left or the top, 100 the right or the bottom, 50 the middle.
        public var position: Double
        /// 1 is the wallpaper's own speed.
        public var speed: Double

        public init(scaling: Scaling = .fill, position: Double = 50, speed: Double = 1) {
            self.scaling = scaling
            self.position = position
            self.speed = speed
        }
    }

    /// The settings to show the wallpaper with: its own, or the usual ones until it has any.
    public var shownSettings: Settings { settings ?? Settings() }

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
        dateAdded: Date = Date(),
        settings: Settings? = nil
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
        self.settings = settings
    }
}
