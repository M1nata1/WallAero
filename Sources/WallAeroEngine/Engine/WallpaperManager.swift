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
    /// What was found in the user's music folder; nil when no folder is chosen.
    @Published private(set) var musicFolder: MusicFolder?

    /// The user's music. When there is any, it plays in place of the videos' own sound.
    let music = PlaylistPlayer()

    private static let assignmentsKey = "assignments"

    private let library: WallpaperLibrary
    private let preferences: Preferences
    private var screens: [String: ScreenWallpaper] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var displaysAsleep = false
    private var screenLocked = false
    private var sessionActive = true
    /// The music folder being read in the background, so the same scan is not started twice.
    private var scanningMusicPath: String?
    /// Web wallpapers whose pictures are due to be rendered again, once the edits settle.
    private var pendingWebRefresh: [UUID: Task<Void, Never>] = [:]
    /// Stills of web wallpapers being rendered, so two displays do not render the same one twice.
    private var webStillTasks: [UUID: Task<URL, Error>] = [:]
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

    /// Scaling and speed used to be set once for all wallpapers. The first time this version
    /// runs, the wallpapers of the library take those values as their own.
    private func handOverSharedSettings() {
        let key = "wallpapersHaveOwnSettings"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let shared = Wallpaper.Settings(scaling: preferences.scaling, speed: preferences.playbackRate)
        guard shared != Wallpaper.Settings() else { return }
        library.adoptSettings { _ in shared }
    }

    func start() {
        handOverSharedSettings()
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
        workspace.addObserver(self, selector: #selector(activeSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

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
        reloadMusic()
        // Scenes edited by hand while the app was not looking get their thumbnails redone.
        for item in library.items where item.kind == .web {
            refreshPicturesIfOutdated(of: item)
        }
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
        // With music of the user's own, none does: the music takes the place of the videos' sound.
        let audibleDisplay = playsMusic ? nil : displays.first { screens[$0.id]?.item?.hasAudio == true }?.id
        // With the volume all the way down nothing is heard, so nothing is played: a video or
        // a song at volume zero would still keep the audio hardware running and the Mac awake.
        for screen in screens.values {
            if let item = screen.item {
                screen.view.setFraming(item.shownSettings.scaling, position: item.shownSettings.position,
                                       mediaSize: CGSize(width: item.pixelWidth, height: item.pixelHeight))
            }
            let audible = isAudible && screen.displayID == audibleDisplay
            screen.view.setAudio(muted: !audible, volume: Float(preferences.volume))
        }
        music.volume = Float(preferences.volume)
        SoundSpectrum.shared.isEnabled = preferences.reactsToSound
    }

    /// Starts or stops every player according to the current state of the Mac.
    func updatePlayback() {
        let reason = currentPauseReason()
        if reason != pauseReason {
            pauseReason = reason
        }
        for screen in screens.values {
            let visible = !preferences.pauseWhenCovered || screen.isVisibleOnScreen
            screen.setPlaying(pauseReason == nil && visible, rate: Float(screen.item?.shownSettings.speed ?? 1))
        }
        // Unlike the picture, the music goes on while windows cover the desktop: songs that
        // stopped whenever a window was maximized would be of little use.
        music.setPlaying(playsMusic && isAudible && hasWallpaper && pauseReason == nil)
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
        reloadMusic()
        syncSystemWallpapers()
    }

    /// A wallpaper that is on a display now: the one for all displays, or else any display's own.
    var shownWallpaperID: UUID? {
        assignments.allDisplays ?? displays.lazy.compactMap { self.assignments.wallpaperID(forDisplay: $0.id) }.first
    }

    /// Shows a scene on the desktop as it is being changed in the wallpaper's settings, without
    /// waiting for it to be saved.
    func showUnsaved(_ scene: WallpaperScene, of id: UUID) {
        guard let data = try? SceneProject.encoded(scene, readable: false) else { return }
        let script = "window.wallaero && window.wallaero.setScene(\(String(decoding: data, as: UTF8.self)))"
        for screen in screens.values where screen.item?.id == id {
            screen.view.webView?.evaluate(script)
        }
    }

    // MARK: - Web wallpapers

    /// The files of a web wallpaper changed. Once the edits settle, its thumbnail is rendered
    /// again, and its still too if it serves as the macOS wallpaper.
    func webWallpaperDidChange(_ item: Wallpaper) {
        pendingWebRefresh[item.id]?.cancel()
        pendingWebRefresh[item.id] = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            pendingWebRefresh[item.id] = nil
            await refreshPictures(of: item)
        }
    }

    /// A web wallpaper is watched only while it is on screen. If its files were changed in the
    /// meantime, its thumbnail and still show the old look; this notices and has them redone.
    func refreshPicturesIfOutdated(of item: Wallpaper) {
        let folder = library.projectURL(for: item)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        let changed = files.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
        let thumbnail = library.thumbnailURL(for: item)
            .flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard let changed, thumbnail.map({ $0 < changed }) ?? true else { return }
        webWallpaperDidChange(item)
    }

    /// Renders the library thumbnail of a web wallpaper and drops its still, which is rendered
    /// again when next needed.
    func refreshPictures(of item: Wallpaper) async {
        guard let current = library.item(withID: item.id), current.kind == .web,
              let project = WebProject(folder: library.projectURL(for: current))
        else {
            return
        }
        if let picture = await WebSnapshotter.render(project, size: NSSize(width: 960, height: 540)) {
            if let old = library.thumbnailURL(for: current) {
                ThumbnailCache.forget(old)
            }
            library.setThumbnail(WebSnapshotter.thumbnail(from: picture), for: current.id)
        }
        library.removeStill(for: current)
        resyncSystemWallpapers()
    }

    /// The still of a web wallpaper, rendered at the display's size if there is none yet.
    private func webStill(for item: Wallpaper, size: NSSize) async throws -> URL {
        if let rendered = library.renderedStillURL(for: item) {
            return rendered
        }
        if let running = webStillTasks[item.id] {
            return try await running.value
        }
        let task = Task { () throws -> URL in
            defer { webStillTasks[item.id] = nil }
            guard let project = WebProject(folder: library.projectURL(for: item)),
                  let picture = await WebSnapshotter.render(project, size: size, forStill: true)
            else {
                throw ImportError.unreadable
            }
            return try library.setStill(picture, for: item)
        }
        webStillTasks[item.id] = task
        return try await task.value
    }

    // MARK: - Music

    /// Whether the user's music plays in place of the videos' own sound.
    var playsMusic: Bool { preferences.playsSound && music.hasTracks }

    /// Whether anything can be heard at all: sound is on and the volume is above zero.
    private var isAudible: Bool { preferences.playsSound && preferences.volume > 0 }

    /// Brings the player in line with the chosen folder, playlist and order. The folder is read
    /// off the main thread: a large collection takes a moment.
    private func reloadMusic() {
        guard let path = preferences.musicFolderPath else {
            scanningMusicPath = nil
            musicFolder = nil
            applyMusicSelection()
            return
        }
        guard path != musicFolder?.url.path else {
            applyMusicSelection()
            return
        }
        guard path != scanningMusicPath else { return }
        scanningMusicPath = path
        Task {
            let folder = await Task.detached(priority: .userInitiated) {
                MusicFolder.scan(URL(fileURLWithPath: path))
            }.value
            guard scanningMusicPath == path else { return } // another folder was chosen meanwhile
            scanningMusicPath = nil
            musicFolder = folder
            applyMusicSelection()
        }
    }

    /// Reads the music folder so the settings can list its playlists, without playing anything.
    /// For the screenshot helper, which never starts the manager.
    func readMusicFolderForDisplay() async {
        guard let path = preferences.musicFolderPath else { return }
        musicFolder = await Task.detached(priority: .userInitiated) {
            MusicFolder.scan(URL(fileURLWithPath: path))
        }.value
    }

    private func applyMusicSelection() {
        // A playlist that was renamed or deleted: back to all the music, so the picker shows a choice.
        if let chosen = preferences.musicPlaylist, let playlists = musicFolder?.playlists,
           !playlists.isEmpty, !playlists.contains(where: { $0.name == chosen }) {
            preferences.musicPlaylist = nil
        }
        let tracks = musicFolder?.tracks(inPlaylist: preferences.musicPlaylist) ?? []
        music.setTracks(tracks, shuffled: preferences.shufflesMusic)
        applyPlaybackSettings()
        updatePlayback()
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
    ///
    /// macOS keeps a desktop picture for every Space, and `setDesktopImageURL` changes only the
    /// Space in front. `resyncSystemWallpapers` therefore runs again whenever another Space comes
    /// to the front, so each one is corrected as soon as it is shown; otherwise the lock screen
    /// would show whatever picture that Space had before.
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
                    let url = item.kind == .web
                        ? try await webStill(for: item, size: screen.frame.size)
                        : try await library.stillImageURL(for: item)
                    // What macOS reports is for the Space in front; skip it if it is right already.
                    let current = NSWorkspace.shared.desktopImageURL(for: screen)
                    guard current?.standardizedFileURL != url.standardizedFileURL else {
                        return
                    }
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                        .allowClipping: true,
                    ])
                    Log.playback.notice("System wallpaper on \(screen.localizedName, privacy: .public): “\(item.name, privacy: .public)” replaces \(current?.lastPathComponent ?? "nothing", privacy: .public)")
                } catch {
                    syncedSystemWallpapers[displayID] = nil
                    NSLog("WallAero Engine: cannot set the system wallpaper: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Checks the picture again against what macOS has now, not against what was set last.
    private func resyncSystemWallpapers() {
        syncedSystemWallpapers = [:]
        syncSystemWallpapers()
    }

    @objc private func activeSpaceDidChange() {
        resyncSystemWallpapers()
        // Once more when the switch animation is over, in case macOS still reported the old Space.
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            resyncSystemWallpapers()
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
        resyncSystemWallpapers()
    }

    @objc private func sessionDidResignActive() {
        sessionActive = false
        updatePlayback()
    }

    @objc private func sessionDidBecomeActive() {
        sessionActive = true
        updatePlayback()
        resyncSystemWallpapers()
    }

    @objc private func screenDidLock() {
        screenLocked = true
        updatePlayback()
    }

    @objc private func screenDidUnlock() {
        screenLocked = false
        updatePlayback()
        resyncSystemWallpapers()
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
    /// Tells a wallpaper that became ready late that another one has been asked for since.
    private var showGeneration = 0
    /// A wallpaper that cannot be shown is not waited for longer than this.
    private static let longestWaitForPicture: TimeInterval = 3

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
        if playing != isPlaying, let item, item.kind != .image {
            Log.playback.info("\(playing ? "Playing" : "Paused", privacy: .public) “\(item.name, privacy: .public)” on \(self.window.screen?.localizedName ?? self.displayID, privacy: .public)")
        }
        isPlaying = playing
        view.setPlaying(playing, rate: rate)
    }

    func show(_ newItem: Wallpaper?, from library: WallpaperLibrary) {
        guard newItem?.id != item?.id else {
            // The same wallpaper, possibly with other settings; the manager applies those.
            item = newItem
            return
        }
        item = newItem
        isPlaying = false
        guard let newItem else {
            view.clear()
            window.orderOut(nil)
            return
        }
        // The window stays out of sight until the wallpaper has a picture to show. Until then
        // the macOS wallpaper is what is seen, rather than a black screen.
        showGeneration += 1
        let generation = showGeneration
        window.alphaValue = 0
        view.onReady = { [weak self] in self?.reveal(generation) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestWaitForPicture) { [weak self] in
            self?.reveal(generation)
        }
        switch newItem.kind {
        case .video:
            view.showVideo(at: library.fileURL(for: newItem))
        case .image:
            view.showImage(at: library.fileURL(for: newItem))
        case .web:
            guard let project = WebProject(folder: library.projectURL(for: newItem)) else {
                Log.playback.error("The web wallpaper “\(newItem.name, privacy: .public)” has no page to show")
                view.clear()
                break
            }
            view.showWeb(project)
            view.webView?.onContentChange = { [weak self] in
                guard let self else { return }
                self.manager?.webWallpaperDidChange(newItem)
            }
            manager?.refreshPicturesIfOutdated(of: newItem)
        }
        window.orderFrontRegardless()
    }

    private func reveal(_ generation: Int) {
        guard generation == showGeneration, window.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 1
        }
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
