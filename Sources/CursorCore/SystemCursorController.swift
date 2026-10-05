import CGSCursor
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Applies a cursor theme to the whole login session through the private CGS API, and reliably
/// puts the system cursors back.
///
/// Reset works by backing up each role's original images *before* the first time it is changed
/// (unregistering alone does not restore an overridden cursor) and re-registering them verbatim.
/// Backups live on disk, so a reset still works after the app is relaunched. Registrations are
/// per login session, so logging out is the ultimate reset.
@MainActor
public final class SystemCursorController {
    public struct ApplyResult {
        public var applied: [String]      // role display names changed
        public var failed: [String]       // role display names that errored
    }

    private let cid = CGSMainConnectionID()
    private let rootURL: URL
    private let backupURL: URL
    private let stateURL: URL

    /// Name of the theme currently applied, or nil if the system cursors are in use.
    public private(set) var appliedThemeName: String?

    public var isApplied: Bool { appliedThemeName != nil }

    /// The on-screen size the window server currently has registered for a role, for diagnostics.
    public func registeredSize(roleID: String) -> CGSize? {
        var size = CGSize.zero, hot = CGPoint.zero
        var frameCount: UInt = 0, duration: CGFloat = 0
        var array: Unmanaged<CFArray>?
        let err = CGSCopyRegisteredCursorImages(cid, roleID, &size, &hot, &frameCount, &duration, &array)
        _ = array?.takeRetainedValue()
        return err == .success ? size : nil
    }

    public init(rootURL: URL = SystemCursorController.defaultRootURL) {
        self.rootURL = rootURL
        backupURL = rootURL.appendingPathComponent("CursorBackup", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("cursor-state.json")
        try? FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        appliedThemeName = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)))?.themeName
    }

    public nonisolated static var defaultRootURL: URL {
        let home: URL
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent("Library/Application Support/WallAeroEngine", isDirectory: true)
    }

    // MARK: - Apply

    /// Registers every cursor in the theme. `pointSize` is the on-screen size of the longest side.
    @discardableResult
    public func apply(_ theme: CursorTheme, pointSize: CGFloat) -> ApplyResult {
        var result = ApplyResult(applied: [], failed: [])
        for assignment in theme.assignments {
            backUpIfNeeded(roleID: assignment.role.id)
            if register(assignment, pointSize: pointSize) {
                result.applied.append(assignment.role.displayName)
            } else {
                result.failed.append(assignment.role.displayName)
            }
        }
        if !result.applied.isEmpty {
            appliedThemeName = theme.name
            try? JSONEncoder().encode(State(themeName: theme.name)).write(to: stateURL)
        }
        return result
    }

    // MARK: - Keeping the theme

    /// The theme's cursors that no longer hold its images, e.g. because macOS registered its own
    /// again. An app that keeps a theme applied looks from time to time. Changes nothing.
    public func replacedAssignments(in theme: CursorTheme, pointSize: CGFloat) -> [CursorAssignment] {
        theme.assignments.filter { !holds($0, pointSize: pointSize) }
    }

    public struct RestoreResult {
        public var restored: [String] = []        // role display names put back
        public var failed: [String] = []          // role display names that errored
        /// Role IDs that still read back as the system's cursor right after registering ours (as
        /// macOS 26 appears to do with the older Arrow and IBeam names). Retrying them is pointless.
        public var notKept: Set<String> = []
    }

    /// Registers again every cursor of the theme that macOS has replaced, except `ignoring`.
    @discardableResult
    public func restoreReplaced(_ theme: CursorTheme, pointSize: CGFloat, ignoring: Set<String> = []) -> RestoreResult {
        var result = RestoreResult()
        for assignment in replacedAssignments(in: theme, pointSize: pointSize) where !ignoring.contains(assignment.role.id) {
            if !register(assignment, pointSize: pointSize) {
                result.failed.append(assignment.role.displayName)
            } else if holds(assignment, pointSize: pointSize) {
                result.restored.append(assignment.role.displayName)
            } else {
                result.notKept.insert(assignment.role.id)
            }
        }
        return result
    }

    /// Whether the window server still has the assignment's cursor: the same size, hot spot and
    /// frame count as registered. The system's own cursors differ in at least one of them.
    private func holds(_ assignment: CursorAssignment, pointSize: CGFloat) -> Bool {
        let expected = Registration(assignment, pointSize: pointSize)
        var size = CGSize.zero
        var hot = CGPoint.zero
        var frameCount: UInt = 0
        var duration: CGFloat = 0
        var array: Unmanaged<CFArray>?
        let err = CGSCopyRegisteredCursorImages(cid, assignment.role.id, &size, &hot, &frameCount, &duration, &array)
        _ = array?.takeRetainedValue()
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }
        return err == .success && Int(frameCount) == expected.frames.count
            && same(size.width, expected.size.width) && same(size.height, expected.size.height)
            && same(hot.x, expected.hotSpot.x) && same(hot.y, expected.hotSpot.y)
    }

    // MARK: - Reset

    /// Restores every backed-up cursor and forgets the applied theme.
    public func reset() {
        let backups = (try? FileManager.default.contentsOfDirectory(at: backupURL, includingPropertiesForKeys: nil)) ?? []
        for file in backups where file.pathExtension == "json" {
            guard let backup = try? JSONDecoder().decode(Backup.self, from: Data(contentsOf: file)) else { continue }
            if backup.absent == true {
                // The window server had no such cursor before; removing ours brings back its built-in one.
                // The flag must be true: with false the call succeeds but removes nothing.
                _ = CGSRemoveRegisteredCursor(cid, backup.roleID, true)
                continue
            }
            let images = backup.imageFiles.compactMap { loadImage(backupURL.appendingPathComponent($0)) }
            guard !images.isEmpty else { continue }
            _ = registerRaw(images: images, roleID: backup.roleID,
                            size: CGSize(width: backup.width, height: backup.height),
                            hotSpot: CGPoint(x: backup.hotX, y: backup.hotY),
                            frameCount: backup.frameCount, frameDuration: backup.frameDuration)
        }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stateURL)
        appliedThemeName = nil
    }

    // MARK: - Backup

    private func backUpIfNeeded(roleID: String) {
        let jsonURL = backupURL.appendingPathComponent(sanitized(roleID) + ".json")
        guard !FileManager.default.fileExists(atPath: jsonURL.path) else { return }

        var size = CGSize.zero
        var hot = CGPoint.zero
        var frameCount: UInt = 0
        var duration: CGFloat = 0
        var array: Unmanaged<CFArray>?
        let err = CGSCopyRegisteredCursorImages(cid, roleID, &size, &hot, &frameCount, &duration, &array)
        // "Copy" returns a +1 reference; takeRetainedValue balances it.
        guard err == .success, let cfArray = array?.takeRetainedValue() else {
            // Not registered yet (macOS creates some cursors on first use): remember that, so
            // reset removes ours instead of restoring something.
            let marker = Backup(roleID: roleID, width: 0, height: 0, hotX: 0, hotY: 0,
                                frameCount: 0, frameDuration: 0, imageFiles: [], absent: true)
            try? JSONEncoder().encode(marker).write(to: jsonURL)
            return
        }

        let images = cgImages(from: cfArray)
        var fileNames: [String] = []
        for (index, image) in images.enumerated() {
            let name = "\(sanitized(roleID))-\(index).png"
            if saveImage(image, to: backupURL.appendingPathComponent(name)) {
                fileNames.append(name)
            }
        }
        guard !fileNames.isEmpty else { return }
        let backup = Backup(roleID: roleID, width: Double(size.width), height: Double(size.height),
                            hotX: Double(hot.x), hotY: Double(hot.y),
                            frameCount: Int(frameCount), frameDuration: Double(duration), imageFiles: fileNames)
        try? JSONEncoder().encode(backup).write(to: jsonURL)
    }

    // MARK: - Registration

    /// What gets registered for an assignment: its frames fitted to the frame limit, scaled so
    /// the longest side is `pointSize`.
    private struct Registration {
        let frames: [CGImage]
        let frameDuration: CGFloat
        let size: CGSize      // points
        let hotSpot: CGPoint  // points

        init(_ assignment: CursorAssignment, pointSize: CGFloat) {
            let decoded = assignment.decoded
            let animation = SystemCursorController.fitToFrameLimit(decoded.frames, durations: decoded.frameDurations)
            let scale = pointSize / max(decoded.pixelSize.width, decoded.pixelSize.height, 1)
            frames = animation.frames
            frameDuration = CGFloat(animation.frameDuration)
            size = CGSize(width: decoded.pixelSize.width * scale, height: decoded.pixelSize.height * scale)
            hotSpot = CGPoint(x: decoded.hotSpot.x * scale, y: decoded.hotSpot.y * scale)
        }
    }

    private func register(_ assignment: CursorAssignment, pointSize: CGFloat) -> Bool {
        let registration = Registration(assignment, pointSize: pointSize)
        // The window server stores an animated cursor as ONE image: a vertical strip of all
        // frames (height = frameHeight × frameCount), not an array of separate frames. Building
        // the strip also normalises the pixel format, which the raw ImageIO frames are not in.
        guard let strip = verticalStrip(registration.frames, frameSize: assignment.decoded.pixelSize) else { return false }
        return registerRaw(images: [strip], roleID: assignment.role.id, size: registration.size,
                           hotSpot: registration.hotSpot, frameCount: registration.frames.count,
                           frameDuration: registration.frameDuration)
    }

    /// Stacks the frames top-to-bottom into one RGBA image.
    private func verticalStrip(_ frames: [CGImage], frameSize: CGSize) -> CGImage? {
        let width = Int(frameSize.width.rounded())
        let height = Int(frameSize.height.rounded())
        guard width > 0, height > 0, !frames.isEmpty,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height * frames.count, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        // Frame 0 goes at the top; Core Graphics' origin is bottom-left.
        for (index, frame) in frames.enumerated() {
            let y = (frames.count - 1 - index) * height
            context.draw(frame, in: CGRect(x: 0, y: y, width: width, height: height))
        }
        return context.makeImage()
    }

    private func registerRaw(images: [CGImage], roleID: String, size: CGSize, hotSpot: CGPoint,
                             frameCount: Int, frameDuration: CGFloat) -> Bool {
        var seed: Int32 = 0
        let err = CGSRegisterCursorWithImages(cid, roleID, true, true, size, hotSpot,
                                              UInt(max(frameCount, 1)), frameDuration,
                                              images as CFArray, &seed)
        return err == .success
    }

    // MARK: - Image (de)serialization

    private func cgImages(from array: CFArray) -> [CGImage] {
        (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            return unsafeBitCast(raw, to: CGImage.self)
        }
    }

    private func saveImage(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The window server rejects animated cursors with more than 24 frames (error 1000).
    nonisolated static let maximumFrameCount = 24

    /// Prepares an animation for registration, which takes one duration for all frames. Longer
    /// animations are resampled evenly over time down to `maximumFrameCount` frames, keeping the
    /// loop length; shorter ones keep their frames and use the average duration.
    nonisolated static func fitToFrameLimit(_ frames: [CGImage], durations: [Double]) -> (frames: [CGImage], frameDuration: Double) {
        let timed = durations.prefix(frames.count).map { max($0, 0) }
        let total = timed.reduce(0, +)
        guard frames.count > maximumFrameCount, total > 0, timed.count == frames.count else {
            let nonZero = timed.filter { $0 > 0 }
            return (Array(frames.prefix(maximumFrameCount)), nonZero.isEmpty ? 0 : nonZero.reduce(0, +) / Double(nonZero.count))
        }
        let count = maximumFrameCount
        var sampled: [CGImage] = []
        var index = 0
        var elapsed = 0.0
        for step in 0..<count {
            // Take the frame on screen at the middle of each new, equal time slot.
            let time = (Double(step) + 0.5) * total / Double(count)
            while index < frames.count - 1, elapsed + timed[index] <= time {
                elapsed += timed[index]
                index += 1
            }
            sampled.append(frames[index])
        }
        return (sampled, total / Double(count))
    }

    private func sanitized(_ roleID: String) -> String {
        roleID.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Persisted types

    private struct State: Codable { var themeName: String }

    private struct Backup: Codable {
        var roleID: String
        var width: Double
        var height: Double
        var hotX: Double
        var hotY: Double
        var frameCount: Int
        var frameDuration: Double
        var imageFiles: [String]
        /// The cursor was not registered before it was themed. Optional so older backups decode.
        var absent: Bool? = nil
    }
}
