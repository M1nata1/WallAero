import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

/// The scene being edited: what the inspector and the layer list bind to, what the preview shows.
/// Every change is saved to `scene.json` a moment later, so a wallpaper that is on the desktop
/// follows the editor live.
@MainActor
final class SceneEditorModel: ObservableObject {
    let folder: URL
    let title: String

    @Published var scene: WallpaperScene {
        didSet { sceneDidChange(from: oldValue) }
    }
    /// The selected layer; nil means the background.
    @Published var selection: UUID? {
        didSet {
            if selection != oldValue {
                preview?.select(selection)
            }
        }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Called after the scene was written to disk.
    var onSave: (() -> Void)?
    weak var preview: SceneEditorPreviewController?

    private var undoStack: [WallpaperScene] = []
    private var redoStack: [WallpaperScene] = []
    private var lastChange = Date.distantPast
    private var isApplyingHistory = false
    private var changeComesFromPreview = false
    private var saveTask: Task<Void, Never>?
    /// The scene as it is on disk, as far as the editor knows: what it read or last wrote.
    private var savedScene: WallpaperScene

    init(folder: URL, title: String) throws {
        self.folder = folder
        self.title = title
        let stored = try SceneProject.read(from: folder)
        scene = stored
        savedScene = stored
    }

    // MARK: - Changes

    private func sceneDidChange(from old: WallpaperScene) {
        guard scene != old else { return }
        if !isApplyingHistory {
            // Changes that follow closely — a slider being dragged, a layer being moved — are one
            // step to undo; a pause starts the next one.
            if Date().timeIntervalSince(lastChange) > 0.6 {
                undoStack.append(old)
                if undoStack.count > 200 {
                    undoStack.removeFirst()
                }
                redoStack = []
            }
            lastChange = Date()
        }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if let selection, !scene.layers.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if !changeComesFromPreview {
            preview?.show(scene)
        }
        scheduleSave()
    }

    /// The next change starts a new step to undo, however soon it comes.
    func endGesture() {
        lastChange = .distantPast
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(scene)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(scene)
        restore(next)
    }

    private func restore(_ other: WallpaperScene) {
        isApplyingHistory = true
        scene = other
        isApplyingHistory = false
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        endGesture()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Writes the scene at once, if it has changed; the window calls it when closing.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard scene != savedScene else { return }
        do {
            try SceneProject.write(scene, to: folder)
            savedScene = scene
            onSave?()
        } catch {
            Log.playback.error("Cannot save the scene \(self.folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The scene file changed on disk. If that was not the editor's own doing — the file was
    /// edited by hand, or by another program — the editor takes the new scene over, as one step
    /// that can be undone.
    func sceneFileDidChange() {
        guard let stored = try? SceneProject.read(from: folder), stored != savedScene else { return }
        saveTask?.cancel()
        saveTask = nil
        savedScene = stored
        endGesture()
        scene = stored
        endGesture()
    }

    // MARK: - Layers

    /// The layers as the list shows them: the one in front first.
    var layersFrontFirst: [WallpaperScene.Layer] { scene.layers.reversed() }

    var selectedLayer: WallpaperScene.Layer? {
        selection.flatMap { id in scene.layers.first { $0.id == id } }
    }

    /// A binding to one layer, for the inspector. Writes are dropped once the layer is gone.
    func binding(for id: UUID) -> Binding<WallpaperScene.Layer>? {
        guard let layer = scene.layers.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.scene.layers.first { $0.id == id } ?? layer },
            set: { [weak self] value in
                guard let self, let index = self.scene.layers.firstIndex(where: { $0.id == id }) else { return }
                self.scene.layers[index] = value
            }
        )
    }

    func addLayer(_ kind: WallpaperScene.Layer.Kind) {
        var layer = WallpaperScene.Layer(kind: kind, name: uniqueName(Self.defaultName(for: kind)))
        switch kind {
        case .text:
            layer.text = "{HH}:{mm}"
        case .image:
            guard let source = chooseMedia(types: [.image]) else { return }
            layer.source = source
            layer.width = 20
        case .shape:
            layer.width = 30
            layer.height = 30
        case .code:
            layer.width = 30
            layer.height = 20
            layer.html = "<div class=\"hello\">Hello</div>"
            layer.css = ".hello {\n  height: 100%;\n  display: grid;\n  place-items: center;\n  font: 600 4vh -apple-system;\n  color: white;\n}"
        }
        endGesture()
        scene.layers.append(layer)
        selection = layer.id
        endGesture()
    }

    func deleteLayer(_ id: UUID) {
        endGesture()
        scene.layers.removeAll { $0.id == id }
        endGesture()
    }

    func duplicateLayer(_ id: UUID) {
        guard let index = scene.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = scene.layers[index]
        copy.id = UUID()
        copy.name = uniqueName(copy.name)
        copy.x = min(copy.x + 3, 100)
        copy.y = min(copy.y + 3, 100)
        endGesture()
        scene.layers.insert(copy, at: index + 1)
        selection = copy.id
        endGesture()
    }

    func toggleVisibility(of id: UUID) {
        guard let index = scene.layers.firstIndex(where: { $0.id == id }) else { return }
        endGesture()
        scene.layers[index].isVisible.toggle()
        endGesture()
    }

    /// Reorders by the list's rows, where the first row is the layer in front.
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        var frontFirst = layersFrontFirst
        frontFirst.move(fromOffsets: source, toOffset: destination)
        endGesture()
        scene.layers = frontFirst.reversed()
        endGesture()
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(scene.layers.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    static func defaultName(for kind: WallpaperScene.Layer.Kind) -> String {
        switch kind {
        case .text: return NSLocalizedString("Text", comment: "Layer kind")
        case .image: return NSLocalizedString("Image", comment: "Layer kind")
        case .shape: return NSLocalizedString("Shape", comment: "Layer kind")
        case .code: return NSLocalizedString("Code", comment: "Layer kind")
        }
    }

    static func symbol(for kind: WallpaperScene.Layer.Kind) -> String {
        switch kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .shape: return "square.on.circle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: - Media

    /// Lets the user pick a file, copies it into the scene and returns where it is, relative to
    /// the scene. Nil if they cancelled or the copy failed.
    func chooseMedia(types: [UTType]) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try SceneProject.addMedia(url, to: folder)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func chooseBackground(_ kind: WallpaperScene.Background.Kind) {
        guard let source = chooseMedia(types: kind == .video ? [.movie] : [.image]) else { return }
        endGesture()
        scene.background.kind = kind
        scene.background.source = source
        endGesture()
    }

    // MARK: - From the preview

    /// A layer moved, resized or turned with the mouse. The page has drawn it already.
    func applyFromPreview(layer id: UUID, patch: [String: Double]) {
        guard let index = scene.layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = scene.layers[index]
        if let value = patch["x"] { layer.x = value }
        if let value = patch["y"] { layer.y = value }
        if let value = patch["width"] { layer.width = value }
        if let value = patch["height"] { layer.height = value }
        if let value = patch["rotation"] { layer.rotation = value }
        if let value = patch["fontSize"] { layer.fontSize = value }
        changeComesFromPreview = true
        scene.layers[index] = layer
        changeComesFromPreview = false
    }
}
