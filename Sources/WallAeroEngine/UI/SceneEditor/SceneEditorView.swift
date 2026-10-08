import SwiftUI
import WallpaperCore

/// The scene editor's window: layers on the left, the live preview in the middle, the properties
/// of what is selected on the right.
struct SceneEditorView: View {
    @ObservedObject var model: SceneEditorModel
    let preview: SceneEditorPreviewController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                LayerList(model: model)
                    .frame(width: 210)
                Divider()
                SceneEditorPreview(controller: preview)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SceneInspector(model: model)
                    .frame(width: 340)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(WallpaperScene.Layer.Kind.allCases, id: \.self) { kind in
                    Button {
                        model.addLayer(kind)
                    } label: {
                        Label(SceneEditorModel.defaultName(for: kind), systemImage: SceneEditorModel.symbol(for: kind))
                    }
                }
            } label: {
                Label("Add Layer", systemImage: "plus")
            }
            .fixedSize()

            Button(action: model.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")

            Button(action: model.redo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")

            Spacer()

            Button {
                NSWorkspace.shared.open(model.folder)
            } label: {
                Label("Show Folder", systemImage: "folder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The layers, the one in front first, and the background below them all.
private struct LayerList: View {
    @ObservedObject var model: SceneEditorModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("Layers") {
                    ForEach(model.layersFrontFirst) { layer in
                        row(for: layer)
                            .tag(layer.id)
                            .contextMenu {
                                Button("Duplicate") { model.duplicateLayer(layer.id) }
                                Button("Delete", role: .destructive) { model.deleteLayer(layer.id) }
                            }
                    }
                    .onMove { source, destination in
                        model.moveLayers(fromOffsets: source, toOffset: destination)
                    }
                    if model.scene.layers.isEmpty {
                        Text("No layers yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let id = model.selection {
                    model.deleteLayer(id)
                }
            }
            Divider()
            Button {
                model.selection = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Background")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(model.selection == nil ? Color.accentColor.opacity(0.25) : Color.clear)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(for layer: WallpaperScene.Layer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: SceneEditorModel.symbol(for: layer.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(layer.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(layer.isVisible ? 1 : 0.45)
            Spacer(minLength: 4)
            Button {
                model.toggleVisibility(of: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Visible")
        }
    }
}
