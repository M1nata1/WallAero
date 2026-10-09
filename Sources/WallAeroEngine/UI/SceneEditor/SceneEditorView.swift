import SwiftUI
import WallpaperCore

/// The scene editor's window: layers and variables on the left, the live preview in the middle,
/// the properties of what is selected on the right.
struct SceneEditorView: View {
    @ObservedObject var model: SceneEditorModel
    let preview: SceneEditorPreviewController

    var body: some View {
        layout
            .frame(minWidth: 980, minHeight: 600)
    }

    /// The three parts are the system's own sidebar, content and side panel where it has them
    /// for a window like this (macOS 14), and three columns under a line of buttons before that.
    @ViewBuilder
    private var layout: some View {
        if #available(macOS 14.0, *) {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                LayerList(model: model)
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 320)
            } detail: {
                canvas
                    .toolbar {
                        ToolbarItemGroup {
                            addLayerMenu
                            addVariableMenu
                        }
                        ToolbarItemGroup {
                            undoButton
                            redoButton
                        }
                    }
            }
            .inspector(isPresented: .constant(true)) {
                SceneInspector(model: model)
                    .inspectorColumnWidth(340)
                    .toolbar {
                        Spacer()
                        showFolderButton
                    }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    addLayerMenu
                        .fixedSize()
                    addVariableMenu
                        .fixedSize()
                    undoButton
                    redoButton
                    Spacer()
                    showFolderButton
                        .labelStyle(.titleAndIcon)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                HStack(spacing: 0) {
                    LayerList(model: model)
                        .frame(width: 210)
                    Divider()
                    canvas
                    Divider()
                    SceneInspector(model: model)
                        .frame(width: 340)
                }
            }
        }
    }

    private var canvas: some View {
        SceneEditorPreview(controller: preview)
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tools

    private var addLayerMenu: some View {
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
        .labelStyle(.titleAndIcon)
    }

    private var addVariableMenu: some View {
        Menu {
            ForEach(WallpaperScene.Variable.Kind.allCases, id: \.self) { kind in
                Button {
                    model.addVariable(kind)
                } label: {
                    Label(SceneEditorModel.defaultTitle(for: kind), systemImage: SceneEditorModel.symbol(for: kind))
                }
            }
        } label: {
            Label("Add Variable", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.titleAndIcon)
    }

    private var undoButton: some View {
        Button(action: model.undo) {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .labelStyle(.iconOnly)
        .disabled(!model.canUndo)
        .keyboardShortcut("z", modifiers: .command)
        .help("Undo")
    }

    private var redoButton: some View {
        Button(action: model.redo) {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .labelStyle(.iconOnly)
        .disabled(!model.canRedo)
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .help("Redo")
    }

    private var showFolderButton: some View {
        Button {
            NSWorkspace.shared.open(model.folder)
        } label: {
            Label("Show Folder", systemImage: "folder")
        }
        .help("Show Folder")
    }
}

/// The layers, the one in front first, the scene's variables, and the background below them all.
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
                if !model.scene.variables.isEmpty {
                    Section("Variables") {
                        ForEach(model.scene.variables) { variable in
                            HStack(spacing: 8) {
                                Image(systemName: SceneEditorModel.symbol(for: variable.kind))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(verbatim: variable.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .tag(variable.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { model.delete(variable.id) }
                            }
                        }
                        .onMove { source, destination in
                            model.moveVariables(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let id = model.selection {
                    model.delete(id)
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
