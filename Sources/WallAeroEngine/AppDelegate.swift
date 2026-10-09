import AppKit
import Combine
import SwiftUI
import WallpaperCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library: WallpaperLibrary
    private let preferences: Preferences
    private let manager: WallpaperManager
    private let importer: ImportCoordinator
    private let cursorSettings = CursorSettings()
    private var windows: WindowManager!
    private var statusMenu: StatusMenuController?
    private var cancellables: Set<AnyCancellable> = []
    private var isLaunched = false
    private var urlsOpenedBeforeLaunch: [URL] = []

    static func main() {
        DevelopmentRun.prepare()
        let app = NSApplication.shared
        if let request = ScreenshotMode.renderRequest {
            // A developer's helper that needs neither the library nor the rest of the app.
            ScreenshotMode.renderWeb(request)
            app.run()
            return
        }
        if let request = ScreenshotMode.editRequest {
            ScreenshotMode.editScene(request)
            app.run()
            return
        }
        if let target = ScreenshotMode.energyTestTarget {
            ScreenshotMode.energyTest(target)
            app.run()
            return
        }
        if let folder = ScreenshotMode.settingsTestFolder {
            ScreenshotMode.settingsTest(folder)
            app.run()
            return
        }
        if let target = ScreenshotMode.readyTestTarget {
            ScreenshotMode.readyTest(target)
            app.run()
            return
        }
        if let seconds = ScreenshotMode.soundTestSeconds {
            ScreenshotMode.soundTest(seconds: seconds)
            app.run()
            return
        }
        // The screenshot helper runs next to the copy in use and must not move its data.
        if ScreenshotMode.outputDirectory == nil {
            LegacyMigration.run()
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    override init() {
        // The screenshot helper can be pointed at another library, to picture things the
        // user's own does not have.
        library = ScreenshotMode.libraryFolder.map { WallpaperLibrary(rootURL: $0) } ?? WallpaperLibrary()
        preferences = Preferences()
        manager = WallpaperManager(library: library, preferences: preferences)
        importer = ImportCoordinator(library: library, manager: manager)
        super.init()
        windows = WindowManager(main: { [unowned self] in
            AnyView(
                MainView(actions: LibraryActions(
                    addFiles: { [unowned self] in addWallpapers(nil) },
                    edit: { [unowned self] item in edit(item) }
                ))
                .environmentObject(library)
                .environmentObject(manager)
                .environmentObject(importer)
                .environmentObject(preferences)
                .environmentObject(cursorSettings)
                .environmentObject(windows.state)
            )
        })
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = ScreenshotMode.outputDirectory {
            // Documentation helper; runs alongside the copy in use, so it skips the checks below.
            ScreenshotMode.run(to: directory, library: library, preferences: preferences,
                               manager: manager, importer: importer, cursorSettings: cursorSettings)
            return
        }
        if activateRunningCopy() {
            return
        }
        NSApp.mainMenu = makeMainMenu()
        manager.start()
        cursorSettings.reapplyIfNeeded()
        statusMenu = StatusMenuController(library: library, manager: manager, actions: .init(
            openLibrary: { [unowned self] in showLibrary(nil) },
            addFiles: { [unowned self] in addWallpapers(nil) },
            openSettings: { [unowned self] in showSettings(nil) },
            showAbout: { [unowned self] in showAbout(nil) }
        ))
        importer.$failures
            .filter { !$0.isEmpty }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.presentImportFailures() }
            .store(in: &cancellables)

        isLaunched = true
        if !urlsOpenedBeforeLaunch.isEmpty {
            open(urlsOpenedBeforeLaunch)
            urlsOpenedBeforeLaunch = []
        } else if library.items.isEmpty {
            // First launch: show where to start instead of a lonely menu bar icon.
            windows.showLibrary()
        }
    }

    /// Files opened with the app (Finder's "Open With", dropping on the icon) become the wallpaper.
    func application(_ application: NSApplication, open urls: [URL]) {
        if isLaunched {
            open(urls)
        } else {
            urlsOpenedBeforeLaunch += urls
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showLibrary()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Actions

    @objc func showLibrary(_ sender: Any?) {
        windows.showLibrary()
    }

    @objc func showSettings(_ sender: Any?) {
        windows.showSettings()
    }

    @objc func showSearch(_ sender: Any?) {
        windows.showSearch()
    }

    /// Opens a wallpaper in the scene editor. A video or a picture first becomes a scene with
    /// itself as the background; the original stays in the library as it is.
    func edit(_ item: Wallpaper) {
        if item.kind == .web {
            editScene(item)
            return
        }
        do {
            let name = String(format: NSLocalizedString("%@ (scene)", comment: "Name of a scene made from a wallpaper"), item.name)
            let scene = try library.makeScene(from: item, named: name)
            windows.state.selection = scene.id
            editScene(scene)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens the editor for a scene of the library, or brings it forward if it is open.
    func editScene(_ item: Wallpaper) {
        guard !windows.showOpenEditor(for: item.id) else { return }
        do {
            let model = try SceneEditorModel(folder: library.projectURL(for: item), title: item.name)
            // The library thumbnail and the lock-screen still follow the edits.
            model.onSave = { [weak self] in self?.manager.webWallpaperDidChange(item) }
            let preview = SceneEditorPreviewController(model: model)
            windows.showEditor(for: item.id, title: item.name,
                               content: AnyView(SceneEditorView(model: model, preview: preview)),
                               onClose: { model.saveNow() })
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: NSLocalizedString("Animated wallpapers from videos, GIFs and pictures.", comment: "About panel"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func addWallpapers(_ sender: Any?) {
        windows.showLibrary()
        guard let window = windows.libraryWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaImporter.acceptedContentTypes
        panel.message = NSLocalizedString("Choose videos, GIFs or pictures. Folders are searched too.", comment: "Open panel")
        panel.prompt = NSLocalizedString("Add", comment: "Open panel button")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.importer.importFiles(panel.urls, applyWhenDone: false)
        }
    }

    // MARK: - Helpers

    private func open(_ urls: [URL]) {
        windows.showLibrary()
        importer.importFiles(urls, applyWhenDone: true)
    }

    /// Only one copy may own the desktop; a second launch brings the first one forward.
    private func activateRunningCopy() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0 != current }) else {
            return false
        }
        other.activate(options: [])
        NSApp.terminate(nil)
        return true
    }

    private func presentImportFailures() {
        let failures = importer.failures
        importer.failures = []
        guard let first = failures.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failures.count == 1 {
            alert.messageText = String(format: NSLocalizedString("“%@” could not be added", comment: "Import error title"), first.fileName)
            alert.informativeText = first.message
        } else {
            alert.messageText = NSLocalizedString("Some files could not be added", comment: "Import error title")
            alert.informativeText = failures.prefix(8)
                .map { "\($0.fileName): \($0.message)" }
                .joined(separator: "\n\n")
        }
        if let window = windows.visibleWindow {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("About WallAero Engine", comment: "Menu item"), action: #selector(showAbout(_:)), keyEquivalent: "")
            .setSymbol("info.circle")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Settings…", comment: "Menu item"), action: #selector(showSettings(_:)), keyEquivalent: ",")
            .setSymbol("gearshape")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide WallAero Engine", comment: "Menu item"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Hide Others", comment: "Menu item"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: NSLocalizedString("Show All", comment: "Menu item"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit WallAero Engine", comment: "Menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: "Menu title"))
        fileMenu.addItem(withTitle: NSLocalizedString("Add Wallpapers…", comment: "Menu item"), action: #selector(addWallpapers(_:)), keyEquivalent: "o")
            .setSymbol("plus")
        fileMenu.addItem(withTitle: NSLocalizedString("Open Library…", comment: "Menu item"), action: #selector(showLibrary(_:)), keyEquivalent: "l")
            .setSymbol("square.grid.2x2")
        fileMenu.addItem(withTitle: NSLocalizedString("Find", comment: "Menu item"), action: #selector(showSearch(_:)), keyEquivalent: "f")
            .setSymbol("magnifyingglass")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Close Window", comment: "Menu item"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: "Menu title"))
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: "Menu item"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: "Menu item"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: "Menu item"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: "Menu item"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: "Menu item"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: "Menu item"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: "Menu title"))
        windowMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: "Menu item"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: NSLocalizedString("Zoom", comment: "Menu item"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
