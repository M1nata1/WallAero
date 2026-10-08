import AppKit
import WallpaperCore

/// Renders a web wallpaper to a picture without showing it: the library thumbnail, and the still
/// that goes to macOS as the regular wallpaper.
@MainActor
enum WebSnapshotter {
    /// - Parameters:
    ///   - size: the size to lay the page out at, in points; the picture is twice that in pixels
    ///     on a Retina Mac.
    ///   - forStill: render the picture for the lock screen, without the layers hidden from it.
    static func render(_ project: WebProject, size: NSSize, forStill: Bool = false) async -> CGImage? {
        let view = WebWallpaperView(frame: NSRect(origin: .zero, size: size))
        view.rendersStill = forStill
        // A web view draws only inside a window that is ordered in. This one lies far outside
        // every display, so nothing appears on screen.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.unload()
            window.orderOut(nil)
            window.close()
        }

        view.setPlaying(true, rate: 1)
        view.show(project, watchingForChanges: false)
        await view.waitUntilLoaded()
        // Time for pictures and the first video frame to arrive.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return await view.snapshot()
    }

    /// The picture scaled down for the library grid.
    static func thumbnail(from image: CGImage, width: Int = 640) -> CGImage {
        guard image.width > width else { return image }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
