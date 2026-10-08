import AppKit
import SwiftUI
import WallpaperCore

/// The editor's live picture of the scene: the scene's own page, with the editor script on top
/// so that layers can be picked and moved with the mouse.
@MainActor
final class SceneEditorPreviewController {
    let view: WebWallpaperView
    private weak var model: SceneEditorModel?

    init(model: SceneEditorModel) {
        self.model = model
        view = WebWallpaperView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.editorScript = SceneEditorScript.source
        view.hearsSound = true
        view.onSceneFileChange = { [weak model] in
            model?.sceneFileDidChange()
        }
        view.onEditorMessage = { [weak self] message in
            self?.handle(message)
        }
        view.setAudio(muted: true, volume: 0)
        view.setPlaying(true, rate: 1)
        if let project = WebProject(folder: model.folder) {
            view.show(project)
        }
        model.preview = self
    }

    func show(_ scene: WallpaperScene) {
        guard let data = try? SceneProject.encoded(scene, readable: false) else { return }
        view.evaluate("window.wallaero && window.wallaero.setScene(\(String(decoding: data, as: UTF8.self)))")
    }

    func select(_ id: UUID?) {
        view.evaluate("window.wallaeroEditor && window.wallaeroEditor.select(\(id.map { "'\($0.uuidString)'" } ?? "null"))")
    }

    private func handle(_ message: [String: Any]) {
        guard let model, let type = message["type"] as? String else { return }
        let id = (message["id"] as? String).flatMap(UUID.init(uuidString:))
        switch type {
        case "ready":
            // The page loaded, or loaded again after its files changed: bring it up to date.
            show(model.scene)
            select(model.selection)
        case "select":
            model.selection = id
        case "change":
            if let id, let patch = message["patch"] as? [String: Any] {
                model.applyFromPreview(layer: id, patch: patch.compactMapValues { ($0 as? NSNumber)?.doubleValue })
            }
        case "commit":
            model.endGesture()
        case "delete":
            if let id {
                model.deleteLayer(id)
            }
        default:
            break
        }
    }
}

/// The preview at the proportions of the display the editor is on, centred in the space it is
/// given. Moving the window to another display shows how the scene will look there.
struct SceneEditorPreview: View {
    let controller: SceneEditorPreviewController
    /// Width to height of the display.
    @State private var aspectRatio: CGFloat = 16.0 / 10.0

    private func readAspectRatio() {
        guard let size = (controller.view.window?.screen ?? NSScreen.main)?.frame.size, size.height > 0 else { return }
        aspectRatio = size.width / size.height
    }

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(geometry.size.width - 32, 100), height: max(geometry.size.height - 32, 100))
            let width = min(available.width, available.height * aspectRatio)
            WebPreviewHost(view: controller.view)
                .frame(width: width, height: width / aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            readAspectRatio()
            // Once more when the view has its window.
            DispatchQueue.main.async(execute: readAspectRatio)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { notification in
            if notification.object as? NSWindow === controller.view.window {
                readAspectRatio()
            }
        }
    }
}

private struct WebPreviewHost: NSViewRepresentable {
    let view: WebWallpaperView

    func makeNSView(context: Context) -> WebWallpaperView { view }
    func updateNSView(_ nsView: WebWallpaperView, context: Context) {}
}
