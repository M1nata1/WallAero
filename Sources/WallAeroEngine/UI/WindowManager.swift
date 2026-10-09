import AppKit
import SwiftUI

/// What the main window shows: the wallpaper selected in the library, and the settings at its
/// side. Which settings are open is kept between launches.
@MainActor
final class MainWindowState: ObservableObject {
    /// The settings at the side of the window are of two kinds.
    enum SettingsTab: String {
        /// What the selected wallpaper lets be changed.
        case wallpaper
        /// The app's own settings.
        case general
    }

    /// The width of the settings at the side of the window, in points.
    static let settingsWidth: CGFloat = 420
    private static let showsSettingsKey = "showsSettings"
    private static let settingsTabKey = "settingsTab"
    private let defaults: UserDefaults?

    /// The wallpaper selected in the library.
    @Published var selection: UUID?
    @Published var showsSettings: Bool {
        didSet { defaults?.set(showsSettings, forKey: Self.showsSettingsKey) }
    }
    @Published var settingsTab: SettingsTab {
        didSet { defaults?.set(settingsTab.rawValue, forKey: Self.settingsTabKey) }
    }

    /// Without defaults nothing is read or remembered: the screenshot helper works that way,
    /// next to the copy in use.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        // Until the user hides them, the settings are there, showing the wallpaper's own.
        showsSettings = defaults?.object(forKey: Self.showsSettingsKey) as? Bool ?? true
        settingsTab = defaults?.string(forKey: Self.settingsTabKey).flatMap(SettingsTab.init(rawValue:)) ?? .wallpaper
    }
}

/// Creates the main window and the scene editor windows on demand. While one of them is open
/// the app shows a Dock icon and a main menu; once they are closed it goes back to living in the
/// menu bar.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    /// The main window: the library, and the settings at its side.
    private(set) var libraryWindow: NSWindow?
    let state: MainWindowState
    /// One editor per scene, and what to do when it closes.
    private var editors: [UUID: (window: NSWindow, onClose: () -> Void)] = [:]
    private let makeMainView: () -> AnyView
    private let remembersFrames: Bool

    /// - Parameter remembersFrames: whether windows open where they were closed. The screenshot
    ///   helper, next to the copy in use, neither reads nor writes that.
    init(state: MainWindowState? = nil, remembersFrames: Bool = true, main: @escaping () -> AnyView) {
        self.state = state ?? MainWindowState()
        self.remembersFrames = remembersFrames
        makeMainView = main
    }

    /// The window an alert or open panel should attach to, if any is on screen.
    var visibleWindow: NSWindow? {
        libraryWindow.flatMap { $0.isVisible ? $0 : nil }
    }

    private var allWindows: [NSWindow] {
        [libraryWindow].compactMap { $0 } + editors.values.map(\.window)
    }

    /// Brings the scene's editor to the front if it is open already.
    func showOpenEditor(for id: UUID) -> Bool {
        guard let editor = editors[id] else { return false }
        present(editor.window)
        return true
    }

    func showEditor(for id: UUID, title: String, content: AnyView, onClose: @escaping () -> Void) {
        let window = makeWindow(title: title, content: content, size: NSSize(width: 1240, height: 760),
                                resizable: true, autosaveName: "SceneEditorWindow")
        editors[id] = (window, onClose)
        present(window)
    }

    func showLibrary() {
        let window = libraryWindow ?? makeWindow(
            title: "WallAero Engine",
            content: makeMainView(),
            size: NSSize(width: 1180, height: 700),
            resizable: true,
            autosaveName: "LibraryWindow"
        )
        libraryWindow = window
        present(window)
    }

    /// Opens the app's own settings: the main window, with them at its side.
    func showSettings() {
        showLibrary()
        state.settingsTab = .general
        state.showsSettings = true
    }

    func activateApp() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(_ window: NSWindow) {
        activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, content: AnyView, size: NSSize, resizable: Bool, autosaveName: String) -> NSWindow {
        let window = AppWindow.make(title: title, content: content, size: size, resizable: resizable)
        window.delegate = self
        window.center()
        if remembersFrames {
            window.setFrameAutosaveName(autosaveName)
            window.setFrameUsingName(autosaveName)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let othersVisible = allWindows.contains { $0 !== closing && $0.isVisible }
        editors.first { $0.value.window === closing }?.value.onClose()
        if !othersVisible {
            NSApp.setActivationPolicy(.accessory)
        }
        // Let the closed window go: a hidden window keeps its SwiftUI content alive and updating
        // (the animated cursor previews kept the app at ~20% CPU). It is rebuilt when reopened,
        // at the position saved under its autosave name.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if closing === self.libraryWindow { self.libraryWindow = nil }
            if let id = self.editors.first(where: { $0.value.window === closing })?.key {
                self.editors[id] = nil
            }
        }
    }
}

/// Builds the app's windows around their SwiftUI content. The toolbar and the panels the content
/// declares are handed to the window itself, so every version of macOS draws them its own way:
/// a line of buttons in the title bar before macOS 26, glass over the content since.
@MainActor
enum AppWindow {
    static func make(title: String, content: AnyView, size: NSSize, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            style.insert(.resizable)
        }
        let hostingView = NSHostingView(rootView: content)
        if #available(macOS 14.0, *) {
            // The content reaches under the toolbar, as in the system's own apps.
            style.insert(.fullSizeContentView)
            hostingView.sceneBridgingOptions = [.toolbars]
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        // Let the window be resized freely above the view's minimum size.
        hostingView.sizingOptions = resizable ? [.minSize] : [.minSize, .maxSize]
        window.contentView = hostingView
        window.setContentSize(size)
        return window
    }
}
