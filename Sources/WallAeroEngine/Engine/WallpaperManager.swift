import AppKit
import Combine
import WallpaperCore

enum DisplayTarget: Hashable {
    case all
    case display(String)
}

/// Which wallpaper shows where. Persisted in user defaults.
struct WallpaperAssignments: Codable, Equatable {
    /// Shown on every display that has no choice of its own.
    var allDisplays: UUID?
    /// Per-display choices, keyed by `NSScreen.stableID`. A nil value turns the animated
    /// wallpaper off on that display; a missing key means "same as all displays".
    var displays: [String: UUID?] = [:]

    func wallpaperID(forDisplay id: String) -> UUID? {
        if let choice = displays[id] {
            return choice
        }
        return allDisplays
    }

    var isEmpty: Bool { allDisplays == nil && displays.values.allSatisfy { $0 == nil } }
}

enum PauseReason {
    case user
    case displaysAsleep
    case locked
    case battery
    case lowPowerMode

    var title: String {
        switch self {
        case .user: return NSLocalizedString("Paused", comment: "Playback status")
        case .displaysAsleep: return NSLocalizedString("Paused while displays sleep", comment: "Playback status")
        case .locked: return NSLocalizedString("Paused while the screen is locked", comment: "Playback status")
        case .battery: return NSLocalizedString("Paused on battery power", comment: "Playback status")
        case .lowPowerMode: return NSLocalizedString("Paused in Low Power Mode", comment: "Playback status")
        }
    }
}

/// Owns one desktop window per display and keeps them in sync with the user's choices,
/// the preferences and the state of the Mac (battery, sleep, lock, covered desktop).
@MainActor
final class WallpaperManager: NSObject, ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var assignments: WallpaperAssignments
    @Published var isPausedByUser = false {
        didSet { updatePlayback() }
    }
    @Published private(set) var pauseReason: PauseReason?

    private static let assignmentsKey = "assignments"

    private let library: WallpaperLibrary
    private let preferences: Preferences
    private var screens: [String: ScreenWallpaper] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var displaysAsleep = false
    private var screenLocked = false
    private var sessionActive = true
    /// Still images already handed to macOS, per display, to avoid redundant updates.
    private var syncedSystemWallpapers: [String: UUID] = [:]

    init(library: WallpaperLibrary, preferences: Preferences) {
        self.library = library
        self.preferences = preferences
        if
            let data = UserDefaults.standard.data(forKey: Self.assignmentsKey),
            let stored = try? JSONDecoder().decode(WallpaperAssignments.self, from: data)
        {
            assignments = stored
        } else {
            assignments = WallpaperAssignments()
        }
        super.init()
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        center.addObserver(self, selector: #selector(powerStateDidChange), name: PowerSource.didChangeNotification, object: nil)
        // Low Power Mode changes are posted on a background thread.
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePlayback() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaysDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)

        PowerSource.startMonitoring()

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.preferencesDidChange() }
            .store(in: &cancellables)
        library.$items
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.libraryDidChange() }
            .store(in: &cancellables)

        rebuildScreens()
    }

    // MARK: - Choosing wallpapers

    var hasWallpaper: Bool { !assignments.isEmpty }

    func wallpaperID(for target: DisplayTarget) -> UUID? {
        switch target {
        case .all: return assignments.allDisplays
        case .display(let id): return assignments.wallpaperID(forDisplay: id)
        }
    }

    /// Choosing for all displays replaces every per-display choice, like System Settings does.
    /// Passing nil turns the animated wallpaper off for the target.
    func setWallpaper(_ id: UUID?, for target: DisplayTarget) {
        switch target {
        case .all:
            assignments = WallpaperAssignments(allDisplays: id)
        case .display(let displayID):
            assignments.displays.updateValue(id, forKey: displayID)
        }
        saveAssignments()
        applyAssignments()
    }

    /// Whether the display has its own choice instead of following all displays.
    func hasOwnWallpaper(_ displayID: String) -> Bool {
        assignments.displays.keys.contains(displayID)
    }

    func followAllDisplays(_ displayID: String) {
        assignments.displays.removeValue(forKey: displayID)
        saveAssignments()
        applyAssignments()
    }

    /// Switches every display to the library entry after the current one.
    func showNextWallpaper() {
        let items = library.items
        guard !items.isEmpty else { return }
        let currentIndex = assignments.allDisplays.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        setWallpaper(items[(currentIndex + 1) % items.count].id, for: .all)
    }

    var statusText: String {
        guard hasWallpaper else {
            return NSLocalizedString("No animated wallpaper", comment: "Playback status")
        }
        return pauseReason?.title ?? NSLocalizedString("Playing", comment: "Playback status")
    }

    // MARK: - Screens

    private func rebuildScreens() {
        var remaining = screens
        var updated: [String: ScreenWallpaper] = [:]
        var infos: [DisplayInfo] = []
        for screen in NSScreen.screens {
            var id = screen.stableID
            if updated[id] != nil {
                // Two identical monitors without serial numbers.
                id += "-\(screen.displayNumber ?? 0)"
            }
            if let existing = remaining.removeValue(forKey: id) {
                existing.move(to: screen)
                updated[id] = existing
            } else {
                updated[id] = ScreenWallpaper(screen: screen, displayID: id, manager: self)
            }
            infos.append(DisplayInfo(id: id, name: screen.localizedName))
        }
        for screen in remaining.values {
            screen.close()
        }
        screens = updated
        displays = infos
        applyAssignments()
    }

    private func applyAssignments() {
        for screen in screens.values {
            let item = assignments.wallpaperID(forDisplay: screen.displayID).flatMap(library.item(withID:))
            screen.show(item, from: library)
        }
        applyPlaybackSettings()
        updatePlayback()
        syncSystemWallpapers()
    }

    private func applyPlaybackSettings() {
        // Only one display plays sound: the first one, in menu bar order, showing a video with audio.
        let audibleDisplay = displays.first { screens[$0.id]?.item?.hasAudio == true }?.id
        for screen in screens.values {
            screen.view.setScaling(preferences.scaling)
            let audible = preferences.playsSound && screen.displayID == audibleDisplay
            screen.view.setAudio(muted: !audible, volume: Float(preferences.volume))
        }
    }

    /// Starts or stops every player according to the current state of the Mac.
    func updatePlayback() {
        let reason = currentPauseReason()
        if reason != pauseReason {
            pauseReason = reason
        }
        for screen in screens.values {
            let visible = !preferences.pauseWhenCovered || screen.isVisibleOnScreen
            screen.setPlaying(pauseReason == nil && visible, rate: Float(preferences.playbackRate))
        }
    }

    private func currentPauseReason() -> PauseReason? {
        if isPausedByUser { return .user }
        if displaysAsleep { return .displaysAsleep }
        if screenLocked || !sessionActive { return .locked }
        if preferences.pauseOnBattery && PowerSource.isOnBattery { return .battery }
        if preferences.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        return nil
    }

    // MARK: - Reacting to changes

    private func preferencesDidChange() {
        applyPlaybackSettings()
        updatePlayback()
        syncSystemWallpapers()
    }

    private func libraryDidChange() {
        // Forget wallpapers that were deleted from the library.
        let existing = Set(library.items.map(\.id))
        var cleaned = assignments
        if let id = cleaned.allDisplays, !existing.contains(id) {
            cleaned.allDisplays = nil
        }
        cleaned.displays = cleaned.displays.filter { _, id in id.map(existing.contains) ?? true }
        if cleaned != assignments {
            assignments = cleaned
            saveAssignments()
        }
        applyAssignments()
    }

    private func saveAssignments() {
        if let data = try? JSONEncoder().encode(assignments) {
            UserDefaults.standard.set(data, forKey: Self.assignmentsKey)
        }
    }

    /// Mirrors the wallpaper as a still picture into macOS, when the user asked for it.
    private func syncSystemWallpapers() {
        guard preferences.setsSystemWallpaper else {
            syncedSystemWallpapers = [:]
            return
        }
        for screen in NSScreen.screens {
            guard
                let displayID = screens.first(where: { $0.value.isShown(on: screen) })?.key,
                let item = assignments.wallpaperID(forDisplay: displayID).flatMap(library.item(withID:)),
                syncedSystemWallpapers[displayID] != item.id
            else {
                continue
            }
            syncedSystemWallpapers[displayID] = item.id
            Task {
                do {
                    let url = try await library.stillImageURL(for: item)
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                        .allowClipping: true,
                    ])
                } catch {
                    syncedSystemWallpapers[displayID] = nil
                    NSLog("WallAero Engine: cannot set the system wallpaper: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func screensDidChange() {
        rebuildScreens()
    }

    @objc private func powerStateDidChange() {
        updatePlayback()
    }

    @objc private func displaysDidSleep() {
        displaysAsleep = true
        updatePlayback()
    }

    @objc private func displaysDidWake() {
        displaysAsleep = false
        updatePlayback()
    }

    @objc private func sessionDidResignActive() {
        sessionActive = false
        updatePlayback()
    }

    @objc private func sessionDidBecomeActive() {
        sessionActive = true
        updatePlayback()
    }

    @objc private func screenDidLock() {
        screenLocked = true
        updatePlayback()
    }

    @objc private func screenDidUnlock() {
        screenLocked = false
        updatePlayback()
    }
}

/// The desktop window of a single display.
@MainActor
final class ScreenWallpaper: NSObject {
    let displayID: String
    let view: WallpaperView
    private let window: WallpaperWindow
    private(set) var item: Wallpaper?
    private var isPlaying = false
    private weak var manager: WallpaperManager?

    init(screen: NSScreen, displayID: String, manager: WallpaperManager) {
        self.displayID = displayID
        self.manager = manager
        window = WallpaperWindow(screen: screen)
        view = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()
        window.contentView = view
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionStateDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: window
        )
    }

    /// False while other windows, a full-screen app or the lock screen cover the desktop.
    var isVisibleOnScreen: Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    func isShown(on screen: NSScreen) -> Bool {
        window.screen == screen || window.frame == screen.frame
    }

    func move(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
    }

    func setPlaying(_ playing: Bool, rate: Float) {
        if playing != isPlaying, let item, item.kind == .video {
            Log.playback.info("\(playing ? "Playing" : "Paused", privacy: .public) “\(item.name, privacy: .public)” on \(self.window.screen?.localizedName ?? self.displayID, privacy: .public)")
        }
        isPlaying = playing
        view.setPlaying(playing, rate: rate)
    }

    func show(_ newItem: Wallpaper?, from library: WallpaperLibrary) {
        guard newItem?.id != item?.id else { return }
        item = newItem
        isPlaying = false
        guard let newItem else {
            view.clear()
            window.orderOut(nil)
            return
        }
        switch newItem.kind {
        case .video:
            view.showVideo(at: library.fileURL(for: newItem))
        case .image:
            view.showImage(at: library.fileURL(for: newItem))
        }
        window.orderFrontRegardless()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        view.clear()
        window.orderOut(nil)
        window.close()
    }

    @objc private func occlusionStateDidChange() {
        manager?.updatePlayback()
    }
}
