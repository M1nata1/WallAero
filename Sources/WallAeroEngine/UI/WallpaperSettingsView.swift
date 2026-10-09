import SwiftUI
import WallpaperCore

/// The settings of one wallpaper: what it is, how it fills the screen and how fast it plays,
/// and, for a scene, the variables it puts up for changing. They are for the wallpaper selected
/// in the library, or for the one on the desktop when none is selected.
struct WallpaperSettingsView: View {
    @EnvironmentObject private var library: WallpaperLibrary
    @EnvironmentObject private var manager: WallpaperManager
    @EnvironmentObject private var state: MainWindowState
    @StateObject private var model = WallpaperSettingsModel()
    /// Opens the wallpaper in the scene editor.
    let edit: (Wallpaper) -> Void

    private var item: Wallpaper? {
        (state.selection ?? manager.shownWallpaperID).flatMap(library.item(withID:))
    }

    /// The scene of the wallpaper the settings are for, once it has been read.
    private func scene(of item: Wallpaper) -> WallpaperScene? {
        model.itemID == item.id ? model.scene : nil
    }

    var body: some View {
        Group {
            if let item {
                Form {
                    Section {
                        summary(of: item)
                    }
                    Section("Properties") {
                        properties(of: item)
                    }
                    if let scene = scene(of: item), !scene.variables.isEmpty {
                        Section("Scene") {
                            ForEach(scene.variables) { variable in
                                if let binding = model.binding(for: variable.id) {
                                    VariableValueRow(variable: binding, title: Text(verbatim: variable.title))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("No wallpaper selected")
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { show(item) }
        .onChange(of: item?.id) { _ in show(item) }
    }

    private func show(_ item: Wallpaper?) {
        model.manager = manager
        model.show(item, folder: item.flatMap { library.isScene($0) ? library.projectURL(for: $0) : nil })
    }

    // MARK: - What the wallpaper is

    @ViewBuilder
    private func summary(of item: Wallpaper) -> some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url = library.thumbnailURL(for: item), let image = ThumbnailCache.image(at: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SystemLook.insetCornerRadius, style: .continuous))
        LabeledContent("Name") {
            Text(verbatim: item.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        LabeledContent("Kind") {
            Text(kindTitle(of: item))
        }
        if !item.detailsText.isEmpty {
            LabeledContent("Details") {
                Text(verbatim: item.detailsText)
            }
        }
        if library.canEdit(item) {
            Button {
                edit(item)
            } label: {
                Text(library.editTitle(for: item))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func kindTitle(of item: Wallpaper) -> LocalizedStringKey {
        switch item.kind {
        case .video: return "Video"
        case .image: return "Image"
        case .web: return library.isScene(item) ? "Scene" : "Web Page"
        }
    }

    // MARK: - What every wallpaper lets be set

    @ViewBuilder
    private func properties(of item: Wallpaper) -> some View {
        let settings = Binding(
            get: { library.item(withID: item.id)?.shownSettings ?? item.shownSettings },
            set: { library.setSettings($0, for: item.id) }
        )
        switch item.kind {
        case .video, .image:
            Picker("Scaling", selection: settings.scaling) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if settings.wrappedValue.scaling == .fill {
                NumberRow("Position", value: settings.position, in: 0...100, suffix: "%")
            }
        case .web:
            // A scene fills the screen with its background, and says how in the scene itself.
            if let scene = scene(of: item), scene.background.kind != .color {
                Picker("Scaling", selection: model.fit) {
                    Text(ScalingMode.fill.title).tag(WallpaperScene.Background.Fit.cover)
                    Text(ScalingMode.fit.title).tag(WallpaperScene.Background.Fit.contain)
                    Text(ScalingMode.stretch.title).tag(WallpaperScene.Background.Fit.fill)
                }
                if scene.background.fit == .cover {
                    NumberRow("Position", value: model.position, in: 0...100, suffix: "%")
                }
            }
        }
        if item.kind != .image {
            Picker("Speed", selection: settings.speed) {
                ForEach(Preferences.playbackRates, id: \.self) { rate in
                    Text(Preferences.title(forRate: rate)).tag(rate)
                }
            }
        }
    }
}

/// Holds the scene whose settings are shown. A change shows on the desktop at once and is
/// written to the scene a moment later; the scene is read again when it changes on disk, as it
/// does while its editor is open.
@MainActor
final class WallpaperSettingsModel: ObservableObject {
    @Published private(set) var scene: WallpaperScene?
    private(set) var itemID: UUID?
    weak var manager: WallpaperManager?

    private var item: Wallpaper?
    private var folder: URL?
    private var watcher: FolderWatcher?
    private var saveTask: Task<Void, Never>?
    /// Whether how the background fills the screen was changed here and is yet to be written.
    private var framingChanged = false

    func show(_ item: Wallpaper?, folder: URL?) {
        guard item?.id != itemID || folder != self.folder else { return }
        saveNow()
        self.item = item
        self.folder = folder
        itemID = item?.id
        watcher = nil
        scene = folder.flatMap { try? SceneProject.read(from: $0) }
        guard let folder else { return }
        watcher = FolderWatcher(folder: folder) { [weak self] paths in
            guard paths.contains(where: { ($0 as NSString).lastPathComponent == SceneProject.sceneFileName }) else { return }
            self?.sceneFileDidChange()
        }
    }

    func binding(for id: UUID) -> Binding<WallpaperScene.Variable>? {
        guard let variable = scene?.variables.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.scene?.variables.first { $0.id == id } ?? variable },
            set: { [weak self] value in
                self?.change { scene in
                    guard let index = scene.variables.firstIndex(where: { $0.id == value.id }) else { return }
                    scene.variables[index] = value
                }
            }
        )
    }

    /// How the scene's background fills the screen.
    var fit: Binding<WallpaperScene.Background.Fit> {
        Binding(
            get: { [weak self] in self?.scene?.background.fit ?? .cover },
            set: { [weak self] value in
                self?.framingChanged = true
                self?.change { $0.background.fit = value }
            }
        )
    }

    var position: Binding<Double> {
        Binding(
            get: { [weak self] in self?.scene?.background.position ?? 50 },
            set: { [weak self] value in
                self?.framingChanged = true
                self?.change { $0.background.position = value }
            }
        )
    }

    private func change(_ apply: (inout WallpaperScene) -> Void) {
        guard var changed = scene, let itemID else { return }
        apply(&changed)
        guard changed != scene else { return }
        scene = changed
        manager?.showUnsaved(changed, of: itemID)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        guard let folder, let scene, let item else { return }
        do {
            // Only what was set here goes to disk: the scene may have been edited meanwhile.
            let framing = framingChanged ? (fit: scene.background.fit, position: scene.background.position) : nil
            framingChanged = false
            self.scene = try SceneProject.storeValues(of: scene.variables, framing: framing, in: folder)
            manager?.webWallpaperDidChange(item)
        } catch {
            Log.playback.error("Cannot save the settings of \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sceneFileDidChange() {
        // What is being set here is not yet on disk; it is written over what was read.
        guard saveTask == nil, let folder, let stored = try? SceneProject.read(from: folder), stored != scene else { return }
        scene = stored
    }
}
