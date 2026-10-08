import AppKit
import SwiftUI

/// Creates the library, settings and scene editor windows on demand. While one of them is open
/// the app shows a Dock icon and a main menu; once they are closed it goes back to living in the
/// menu bar.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private(set) var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// One editor per scene, and what to do when it closes.
    private var editors: [UUID: (window: NSWindow, onClose: () -> Void)] = [:]
    private let makeLibraryView: () -> AnyView
    private let makeSettingsView: () -> AnyView

    init(library: @escaping () -> AnyView, settings: @escaping () -> AnyView) {
        makeLibraryView = library
        makeSettingsView = settings
    }

    /// The window an alert or open panel should attach to, if any is on screen.
    var visibleWindow: NSWindow? {
        [libraryWindow, settingsWindow].compactMap { $0 }.first { $0.isVisible }
    }

    private var allWindows: [NSWindow] {
        [libraryWindow, settingsWindow].compactMap { $0 } + editors.values.map(\.window)
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
            content: makeLibraryView(),
            size: NSSize(width: 940, height: 640),
            resizable: true,
            autosaveName: "LibraryWindow"
        )
        libraryWindow = window
        present(window)
    }

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: NSLocalizedString("Settings", comment: "Window title"),
            content: makeSettingsView(),
            size: NSSize(width: 500, height: 600),
            resizable: false,
            autosaveName: "SettingsWindow"
        )
        settingsWindow = window
        present(window)
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
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            style.insert(.resizable)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hostingView = NSHostingView(rootView: content)
        // Let the window be resized freely above the view's minimum size.
        hostingView.sizingOptions = resizable ? [.minSize] : [.minSize, .maxSize]
        window.contentView = hostingView
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName(autosaveName)
        window.setFrameUsingName(autosaveName)
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
            if closing === self.settingsWindow { self.settingsWindow = nil }
            if let id = self.editors.first(where: { $0.value.window === closing })?.key {
                self.editors[id] = nil
            }
        }
    }
}
