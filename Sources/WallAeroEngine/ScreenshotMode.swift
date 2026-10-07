import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

/// Renders the library and settings windows to PNG files for the README (`scripts/screenshots.sh`):
///
///     "build/WallAero Engine.app/Contents/MacOS/WallAeroEngine" --screenshots docs/screenshots
///
/// It runs as a separate process next to the copy in use: it starts no wallpaper and no menu bar
/// icon, and only reads the library and settings. ScreenCaptureKit lets an app capture its own
/// windows without the Screen Recording permission (macOS 14.4+); older systems fall back to
/// drawing the window's views.
@MainActor
enum ScreenshotMode {
    static var outputDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(
        to directory: URL,
        library: WallpaperLibrary,
        preferences: Preferences,
        manager: WallpaperManager,
        importer: ImportCoordinator,
        cursorSettings: CursorSettings
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let libraryView = LibraryView(actions: LibraryActions(addFiles: {}, openSettings: {}))
            .environmentObject(library)
            .environmentObject(manager)
            .environmentObject(importer)
        // Tall enough to show every section without scrolling.
        let settingsHeight: CGFloat = 945
        let settingsView = SettingsView(height: settingsHeight)
            .environmentObject(preferences)
            .environmentObject(library)
            .environmentObject(cursorSettings)

        Task {
            await shoot(AnyView(libraryView), title: "WallAero Engine", size: NSSize(width: 780, height: 440),
                        to: directory.appendingPathComponent("library.png"))
            await shoot(AnyView(settingsView), title: NSLocalizedString("Settings", comment: "Window title"),
                        size: NSSize(width: 500, height: settingsHeight), to: directory.appendingPathComponent("settings.png"))
            NSApp.terminate(nil)
        }
    }

    private static func shoot(_ content: AnyView, title: String, size: NSSize, to url: URL) async {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI lay out, thumbnails load and the window server draw a few frames.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var image: CGImage?
        if #available(macOS 14.4, *) {
            image = try? await captureWithScreenCaptureKit(window)
        }
        image = image ?? drawViews(of: window)
        if let image {
            write(image, to: url)
            print("wrote \(url.path) (\(image.width)×\(image.height))")
        } else {
            print("could not capture \(title)")
        }
        window.close()
    }

    @available(macOS 14.4, *)
    private static func captureWithScreenCaptureKit(_ window: NSWindow) async throws -> CGImage? {
        let content = try await SCShareableContent.currentProcess
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // A shadow would be captured on an opaque black background; the rounded corners stay clear.
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func drawViews(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.cgImage
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
