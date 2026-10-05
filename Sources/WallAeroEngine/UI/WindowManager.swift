import AppKit
import SwiftUI

/// Creates the library and settings windows on demand. While one of them is open the app shows
/// a Dock icon and a main menu; once they are closed it goes back to living in the menu bar.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private(set) var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
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
        let othersVisible = [libraryWindow, settingsWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible
        }
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
        }
    }
}
