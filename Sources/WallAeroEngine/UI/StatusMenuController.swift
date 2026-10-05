import AppKit
import Combine
import WallpaperCore

/// The menu bar icon, the app's main entry point while no window is open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var openLibrary: () -> Void
        var addFiles: () -> Void
        var openSettings: () -> Void
        var showAbout: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let library: WallpaperLibrary
    private let manager: WallpaperManager
    private let actions: Actions
    private var menuThumbnails: [UUID: NSImage] = [:]
    private var cancellable: AnyCancellable?

    init(library: WallpaperLibrary, manager: WallpaperManager, actions: Actions) {
        self.library = library
        self.manager = manager
        self.actions = actions
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "WallAero Engine")
            button.toolTip = "WallAero Engine"
        }
        cancellable = manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        // A dimmed icon tells at a glance that nothing is playing.
        statusItem.button?.appearsDisabled = manager.pauseReason != nil || !manager.hasWallpaper
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: manager.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let pauseTitle = manager.isPausedByUser
            ? NSLocalizedString("Resume", comment: "Menu item")
            : NSLocalizedString("Pause", comment: "Menu item")
        let pause = item(pauseTitle, #selector(togglePause), key: "p", symbol: manager.isPausedByUser ? "play" : "pause")
        pause.isEnabled = manager.hasWallpaper
        menu.addItem(pause)

        let next = item(NSLocalizedString("Next Wallpaper", comment: "Menu item"), #selector(showNextWallpaper), key: "n",
                        symbol: "forward.end")
        next.isEnabled = !library.items.isEmpty
        menu.addItem(next)

        let wallpapers = NSMenuItem(title: NSLocalizedString("Wallpaper", comment: "Menu item"), action: nil, keyEquivalent: "")
        wallpapers.submenu = wallpaperMenu()
        setSymbol("photo.on.rectangle", on: wallpapers)
        menu.addItem(wallpapers)

        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Add Wallpapers…", comment: "Menu item"), #selector(addFiles), key: "o", symbol: "plus"))
        menu.addItem(item(NSLocalizedString("Open Library…", comment: "Menu item"), #selector(openLibrary), key: "l",
                          symbol: "square.grid.2x2"))
        menu.addItem(item(NSLocalizedString("Settings…", comment: "Menu item"), #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("About WallAero Engine", comment: "Menu item"), #selector(showAbout), key: "",
                          symbol: "info.circle"))
        menu.addItem(item(NSLocalizedString("Quit WallAero Engine", comment: "Menu item"), #selector(quit), key: "q", symbol: "power"))
    }

    private func wallpaperMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if library.items.isEmpty {
            let empty = NSMenuItem(title: NSLocalizedString("The library is empty", comment: "Menu item"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let current = manager.wallpaperID(for: .all)
        for wallpaper in library.items {
            let menuItem = item(wallpaper.name, #selector(chooseWallpaper(_:)), key: "")
            menuItem.representedObject = wallpaper.id
            menuItem.state = wallpaper.id == current ? .on : .off
            menuItem.image = menuThumbnail(for: wallpaper)
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let off = item(NSLocalizedString("Turn Off", comment: "Menu item"), #selector(turnOff), key: "", symbol: "stop.circle")
        off.isEnabled = manager.hasWallpaper
        menu.addItem(off)
        return menu
    }

    /// A small aspect-filled copy of the library thumbnail.
    private func menuThumbnail(for wallpaper: Wallpaper) -> NSImage? {
        if let cached = menuThumbnails[wallpaper.id] {
            return cached
        }
        guard let url = library.thumbnailURL(for: wallpaper), let source = ThumbnailCache.image(at: url) else {
            return nil
        }
        let size = NSSize(width: 40, height: 25)
        let scale = max(size.width / source.size.width, size.height / source.size.height)
        let drawn = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).addClip()
        source.draw(in: NSRect(
            x: (size.width - drawn.width) / 2,
            y: (size.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
        thumbnail.unlockFocus()
        menuThumbnails[wallpaper.id] = thumbnail
        return thumbnail
    }

    private func item(_ title: String, _ action: Selector, key: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            setSymbol(symbol, on: item)
        }
        return item
    }

    /// macOS 26 puts a symbol next to some items by itself — a gear by "Settings…" — and indents the
    /// rest of that group to line up with it, so the menu looked ragged. There every item gets its
    /// own symbol, as in the system's menus; earlier systems draw menus without symbols.
    private func setSymbol(_ name: String, on item: NSMenuItem) {
        if #available(macOS 26, *) {
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }

    @objc private func togglePause() { manager.isPausedByUser.toggle() }
    @objc private func showNextWallpaper() { manager.showNextWallpaper() }
    @objc private func turnOff() { manager.setWallpaper(nil, for: .all) }
    @objc private func addFiles() { actions.addFiles() }
    @objc private func openLibrary() { actions.openLibrary() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func showAbout() { actions.showAbout() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func chooseWallpaper(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.setWallpaper(id, for: .all)
    }
}
