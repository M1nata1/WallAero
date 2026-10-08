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
        let settingsHeight: CGFloat = 1025
        let settingsView = SettingsView(height: settingsHeight)
            .environmentObject(preferences)
            .environmentObject(library)
            .environmentObject(manager)
            .environmentObject(cursorSettings)

        Task {
            await manager.readMusicFolderForDisplay()
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
        centerOnSharpestScreen(window)
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

    // MARK: - Rendering a web wallpaper

    /// `--render-web <wallpaper folder> <picture.png> [width height]` draws a web wallpaper off
    /// screen, with the code the app uses for thumbnails and stills, and quits. It touches
    /// neither the library nor the copy in use; handy for checking a scene from a script.
    /// With `--still` the picture is the one for the lock screen.
    static var renderRequest: (folder: URL, output: URL, size: NSSize)? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-web"), index + 2 < arguments.count else { return nil }
        var size = NSSize(width: 960, height: 540)
        if index + 4 < arguments.count, let width = Double(arguments[index + 3]), let height = Double(arguments[index + 4]) {
            size = NSSize(width: width, height: height)
        }
        return (URL(fileURLWithPath: arguments[index + 1], isDirectory: true), URL(fileURLWithPath: arguments[index + 2]), size)
    }

    static func renderWeb(_ request: (folder: URL, output: URL, size: NSSize)) {
        NSApp.setActivationPolicy(.accessory)
        Task {
            guard let project = WebProject(folder: request.folder) else {
                print("no web page in \(request.folder.path)")
                exit(1)
            }
            if CommandLine.arguments.contains("--pause-test") {
                await pauseTest(project, size: request.size)
            }
            let forStill = CommandLine.arguments.contains("--still")
            guard let image = await WebSnapshotter.render(project, size: request.size, forStill: forStill) else {
                print("could not render \(request.folder.path)")
                exit(1)
            }
            write(image, to: request.output)
            print("wrote \(request.output.path) (\(image.width)×\(image.height))")
            exit(0)
        }
    }

    /// `--pause-test`, with `--render-web`: pauses and resumes the wallpaper the way the desktop
    /// window does, and reports whether the page really stood still in between. With
    /// `--needs-user-action` the web engine starts no video by itself, as in Low Power Mode, and
    /// the report shows whether the app got it playing all the same.
    private static func pauseTest(_ project: WebProject, size: NSSize) async {
        let view = WebWallpaperView(frame: NSRect(origin: .zero, size: size))
        view.mediaNeedsUserAction = CommandLine.arguments.contains("--needs-user-action")
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above other windows: a covered page pauses by itself, which would hide what is tested.
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        view.setPlaying(true, rate: 1)
        view.show(project, watchingForChanges: false)
        await view.waitUntilLoaded()
        // Counts animation frames, to see whether the page is running.
        _ = await view.value(of: "window.__frames = 0; (function tick() { window.__frames++; requestAnimationFrame(tick); })(); 1")
        func report(_ label: String) async {
            let state = await view.value(of: "var v = document.querySelector('video'); JSON.stringify({frames: window.__frames, video: v ? (v.paused ? 'paused' : 'playing') + ' at ' + v.currentTime.toFixed(1) : 'none', page: document.visibilityState})")
            print(label.padding(toLength: 22, withPad: " ", startingAt: 0), state as? String ?? "?", "| still shown:", view.isShowingStill)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await report("playing:")
        view.setPlaying(false, rate: 1)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await report("paused, 1 s:")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await report("paused, 2.5 s:")
        view.setPlaying(true, rate: 1)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await report("playing again:")
        view.setPlaying(true, rate: 2)
        view.setAudio(muted: false, volume: 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let media = await view.value(of: "var v = document.querySelector('video'); v ? JSON.stringify({rate: v.playbackRate, muted: v.muted, volume: v.volume}) : 'no video'")
        print("speed 2×, sound on:   ", media as? String ?? "?")
        view.unload()
        window.close()
        fflush(stdout)
    }

    // MARK: - The scene editor

    /// `--edit-scene <scene folder> <picture.png>` opens the scene editor on a folder, takes a
    /// picture of its window and quits; the README's editor screenshot is made this way. Options,
    /// for checking the editor from a script: `--select <layer number, front first>` selects a
    /// layer, `--eval <JavaScript>` runs in the preview first — to act as the mouse would —
    /// and `--add <kind>`, `--background-blur <number>` and `--undo <times>` change the scene the
    /// way the editor's own controls do.
    static var editRequest: (folder: URL, output: URL)? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--edit-scene"), index + 2 < arguments.count else { return nil }
        return (URL(fileURLWithPath: arguments[index + 1], isDirectory: true), URL(fileURLWithPath: arguments[index + 2]))
    }

    private static func values(of option: String) -> [String] {
        let arguments = CommandLine.arguments
        return arguments.indices.filter { arguments[$0] == option && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    static func editScene(_ request: (folder: URL, output: URL)) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let model = try? SceneEditorModel(folder: request.folder, title: request.folder.lastPathComponent) else {
            print("no scene in \(request.folder.path)")
            exit(1)
        }
        let preview = SceneEditorPreviewController(model: model)
        let size = NSSize(width: 1240, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SceneEditorView(model: model, preview: preview))
        window.setContentSize(size)
        centerOnSharpestScreen(window)
        window.makeKeyAndOrderFront(nil)

        Task {
            await preview.view.waitUntilLoaded()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for script in values(of: "--eval") {
                preview.view.evaluate(script)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            for kind in values(of: "--add").compactMap(WallpaperScene.Layer.Kind.init(rawValue:)) {
                model.addLayer(kind)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if let blur = values(of: "--background-blur").last.flatMap(Double.init) {
                model.scene.background.blur = blur
            }
            for _ in 0..<(values(of: "--undo").last.flatMap(Int.init) ?? 0) {
                model.undo()
            }
            if let number = values(of: "--select").last.flatMap(Int.init), model.layersFrontFirst.indices.contains(number - 1) {
                model.selection = model.layersFrontFirst[number - 1].id
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // What the editor holds now, for a script to check.
            print("selection: \(model.selectedLayer?.name ?? "background"); undo: \(model.canUndo)")
            for layer in model.layersFrontFirst {
                print(String(format: "  %@ [%@] x %.2f y %.2f width %.2f height %.2f rotation %.2f size %.2f",
                             layer.name, layer.kind.rawValue, layer.x, layer.y, layer.width, layer.height, layer.rotation, layer.fontSize))
            }
            var image: CGImage?
            if #available(macOS 14.4, *) {
                image = try? await captureWithScreenCaptureKit(window)
            }
            if let image = image ?? drawViews(of: window) {
                write(image, to: request.output)
                print("wrote \(request.output.path) (\(image.width)×\(image.height))")
            }
            model.saveNow()
            exit(0)
        }
    }

    // MARK: - The first picture

    /// `--ready-test <video, picture or web wallpaper folder> [--picture <file.png>]` shows a
    /// wallpaper the way a desktop window does — out of sight until it has a picture — and
    /// prints how long that took and how much of the window was still black when it was revealed.
    /// With `--watch <seconds>` it keeps looking for that long and reports the blackest moment
    /// and whether a web wallpaper's page was loaded anew; `--touch <file name>` rewrites a file
    /// of the wallpaper meanwhile, as saving it in an editor would.
    static var readyTestTarget: URL? {
        values(of: "--ready-test").last.map { URL(fileURLWithPath: $0) }
    }

    static func readyTest(_ target: URL) {
        NSApp.setActivationPolicy(.accessory)
        let size = NSSize(width: 960, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .black
        window.alphaValue = 0
        let view = WallpaperView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        let started = CFAbsoluteTimeGetCurrent()
        view.onReady = {
            let waited = CFAbsoluteTimeGetCurrent() - started
            window.alphaValue = 1
            Task {
                var image: CGImage?
                if #available(macOS 14.4, *) {
                    image = try? await captureWithScreenCaptureKit(window)
                }
                let black = image.map { "\(Int((blackShare(of: $0) * 100).rounded())) %" } ?? "could not look"
                print(String(format: "ready after %.2f s; black when revealed: %@", waited, black))
                if let path = values(of: "--picture").last, let image {
                    write(image, to: URL(fileURLWithPath: path))
                }
                if let seconds = values(of: "--watch").last.flatMap(Double.init) {
                    _ = await view.webView?.value(of: "window.__sameLoad = true; 1")
                    var blackest = 0.0
                    var looks = 0
                    var touched = false
                    let watchStarted = CFAbsoluteTimeGetCurrent()
                    while CFAbsoluteTimeGetCurrent() - watchStarted < seconds {
                        if !touched, CFAbsoluteTimeGetCurrent() - watchStarted > 0.6, let name = values(of: "--touch").last {
                            touched = true
                            let file = target.appendingPathComponent(name)
                            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                            try? (text + "\n").write(to: file, atomically: true, encoding: .utf8)
                        }
                        if #available(macOS 14.4, *), let look = try? await captureWithScreenCaptureKit(window) {
                            blackest = max(blackest, blackShare(of: look))
                            looks += 1
                        }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    let sameLoad = await view.webView?.value(of: "window.__sameLoad === true") as? Bool
                    print("watched \(looks) times: blackest \(Int((blackest * 100).rounded())) %; page loaded anew: \(sameLoad.map { $0 ? "no" : "yes" } ?? "not a page")")
                }
                exit(0)
            }
        }
        view.setScaling(.fill)
        view.setPlaying(true, rate: 1)
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder)
        if isFolder.boolValue, let project = WebProject(folder: target) {
            view.showWeb(project)
        } else if UTType(filenameExtension: target.pathExtension)?.conforms(to: .image) == true {
            view.showImage(at: target)
        } else {
            view.showVideo(at: target)
        }
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !view.isReady else { return }
            print("never became ready")
            exit(1)
        }
    }

    /// How much of a picture is black or nearly so, from 0 to 1.
    private static func blackShare(of image: CGImage) -> Double {
        let width = 96, height = 60
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = { () -> UnsafeMutablePointer<UInt8>? in
                  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                  return context.data?.assumingMemoryBound(to: UInt8.self)
              }()
        else {
            return 1
        }
        var black = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                if Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2]) < 36 { black += 1 }
            }
        }
        return Double(black) / Double(width * height)
    }

    // MARK: - Sound

    /// `--sound-test <seconds>` listens to the Mac's sound the way the app does for a wallpaper
    /// and prints, second by second, the levels that would reach the page. With
    /// `--scene <scene folder>` the scene is shown in a window and the report says what its page
    /// was really given, also while paused; `--picture <file.png>` saves how it looked at the end,
    /// `--eval <JavaScript>` runs in the page before the listening and `--eval-after <JavaScript>`
    /// after it, its value printed. `--switch-off-at <second>` turns the reaction to sound off for
    /// two seconds, as the switch in the settings would.
    ///
    /// macOS grants the listening to the app that was launched, so start it through `open`:
    ///
    ///     open -n -W --stdout report.txt "build/WallAero Engine.app" --args --sound-test 8
    static var soundTestSeconds: Double? {
        values(of: "--sound-test").last.flatMap(Double.init)
    }

    static func soundTest(seconds: Double) {
        NSApp.setActivationPolicy(.accessory)
        final class Probe {
            var frames = 0
            var loudest: Float = 0
            var latest: [Float] = []
        }
        let probe = Probe()
        SoundSpectrum.shared.addListener(probe) { script in
            // The numbers between the brackets of the script a page would run.
            guard let open = script.lastIndex(of: "["), let close = script.lastIndex(of: "]") else { return }
            let levels = script[script.index(after: open)..<close].split(separator: ",").compactMap { Float($0) }
            probe.frames += 1
            probe.latest = levels
            probe.loudest = max(probe.loudest, levels.max() ?? 0)
        }
        func line(_ label: String, page: String? = nil) {
            // Sixteen columns, low notes on the left, in tenths of the full height.
            let levels = probe.latest
            let columns = levels.count == 128
                ? (0..<16).map { column in (column * 4..<column * 4 + 4).map { max(levels[$0], levels[$0 + 64]) }.max() ?? 0 }
                : []
            let picture = columns.map { $0 >= 0.95 ? "#" : String(Int($0 * 10)) }.joined()
            print(label.padding(toLength: 14, withPad: " ", startingAt: 0),
                  String(format: "frames %3d  loudest %.2f  [%@]", probe.frames, probe.loudest, picture), page ?? "")
            fflush(stdout)
            probe.frames = 0
            probe.loudest = 0
        }

        Task {
            var view: WebWallpaperView?
            var window: NSWindow?
            if let folder = values(of: "--scene").last, let project = WebProject(folder: URL(fileURLWithPath: folder, isDirectory: true)) {
                let size = NSSize(width: 960, height: 540)
                let page = WebWallpaperView(frame: NSRect(origin: .zero, size: size))
                page.hearsSound = true
                let host = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled],
                                    backing: .buffered, defer: false)
                host.isReleasedWhenClosed = false
                host.level = .floating // a covered page pauses by itself
                host.contentView = page
                host.orderFrontRegardless()
                page.setPlaying(true, rate: 1)
                page.show(project, watchingForChanges: false)
                await page.waitUntilLoaded()
                _ = await page.value(of: """
                window.__heard = { frames: 0, loudest: 0, length: 0 };
                window.wallpaperRegisterAudioListener(function (levels) {
                  __heard.frames++; __heard.length = levels.length;
                  __heard.loudest = Math.max(__heard.loudest, Math.max.apply(null, levels));
                }); 1
                """)
                for script in values(of: "--eval") {
                    _ = await page.value(of: script)
                }
                view = page
                window = host
            }
            let switchOffAt = values(of: "--switch-off-at").last.flatMap(Int.init)
            func heard() async -> String? {
                guard let view else { return nil }
                let text = await view.value(of: "var h = JSON.stringify(window.__heard); __heard.frames = 0; __heard.loudest = 0; h")
                return "| page: " + (text as? String ?? "?")
            }
            for second in 1...max(1, Int(seconds)) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                line("second \(second):", page: await heard())
                if let switchOffAt, second == switchOffAt || second == switchOffAt + 2 {
                    SoundSpectrum.shared.isEnabled = second != switchOffAt
                    print(SoundSpectrum.shared.isEnabled ? "— switched on —" : "— switched off —")
                }
            }
            if let view {
                for script in values(of: "--eval-after") {
                    print("eval:", await view.value(of: script) ?? "nil")
                }
                if let path = values(of: "--picture").last, let image = await view.snapshot() {
                    write(image, to: URL(fileURLWithPath: path))
                    print("wrote \(path) (\(image.width)×\(image.height))")
                }
                view.setPlaying(false, rate: 1)
                try? await Task.sleep(nanoseconds: 400_000_000)
                _ = await heard()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // The listening goes on for this report, but a paused page must be told nothing.
                line("paused:", page: await heard())
                view.setPlaying(true, rate: 1)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                line("playing again:", page: await heard())
                view.unload()
                window?.close()
            }
            fflush(stdout)
            exit(0)
        }
    }

    /// Pictures are taken at the display's resolution, so a Retina display is preferred to
    /// whichever one happens to have the keyboard focus.
    private static func centerOnSharpestScreen(_ window: NSWindow) {
        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
