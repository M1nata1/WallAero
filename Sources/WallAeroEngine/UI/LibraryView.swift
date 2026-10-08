import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

struct LibraryActions {
    var addFiles: () -> Void
    var openSettings: () -> Void
    /// Opens the scene editor for a scene of the library.
    var editScene: (Wallpaper) -> Void = { _ in }
}

struct LibraryView: View {
    @EnvironmentObject private var library: WallpaperLibrary
    @EnvironmentObject private var manager: WallpaperManager
    @EnvironmentObject private var importer: ImportCoordinator
    let actions: LibraryActions

    @State private var target: DisplayTarget = .all
    @State private var selection: UUID?
    @State private var isDropTargeted = false
    @State private var renamingItem: Wallpaper?
    @State private var newName = ""
    @State private var deletingItem: Wallpaper?

    private var selectedItem: Wallpaper? { selection.flatMap(library.item(withID:)) }
    private var currentID: UUID? { manager.wallpaperID(for: target) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDropTargeted {
                        DropHighlight()
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    Task {
                        importer.importFiles(await Self.fileURLs(from: providers), applyWhenDone: false)
                    }
                    return true
                }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 440)
        .onChange(of: importer.lastImportedID) { id in
            if let id {
                selection = id
            }
        }
        .onChange(of: manager.displays) { displays in
            if case .display(let id) = target, !displays.contains(where: { $0.id == id }) {
                target = .all
            }
        }
        .alert("Rename Wallpaper", isPresented: isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let item = renamingItem {
                    library.rename(item.id, to: newName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deletionTitle, isPresented: isDeleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = deletingItem {
                    delete(item)
                }
            }
        } message: {
            Text("The wallpaper will be removed from the library. The original file is not affected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if manager.displays.count > 1 {
                Picker("Display:", selection: $target) {
                    Text("All Displays").tag(DisplayTarget.all)
                    Divider()
                    ForEach(manager.displays) { display in
                        Text(display.name).tag(DisplayTarget.display(display.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Spacer()
            Button {
                manager.isPausedByUser.toggle()
            } label: {
                if manager.isPausedByUser {
                    Label("Resume", systemImage: "play.fill")
                } else {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            .disabled(!manager.hasWallpaper)
            Button(action: actions.addFiles) {
                Label("Add…", systemImage: "plus")
            }
            Button(action: actions.openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            EmptyLibraryView(addFiles: actions.addFiles)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 20) {
                    ForEach(library.items) { item in
                        WallpaperTile(
                            item: item,
                            thumbnailURL: library.thumbnailURL(for: item),
                            isSelected: selection == item.id,
                            isCurrent: currentID == item.id
                        )
                        .onTapGesture(count: 2) { apply(item) }
                        .simultaneousGesture(TapGesture().onEnded { selection = item.id })
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: Wallpaper) -> some View {
        Button("Set as Wallpaper") { apply(item) }
        if manager.displays.count > 1 {
            Menu("Set for Display") {
                Button("All Displays") { manager.setWallpaper(item.id, for: .all) }
                Divider()
                ForEach(manager.displays) { display in
                    Button(display.name) { manager.setWallpaper(item.id, for: .display(display.id)) }
                }
            }
        }
        if canEdit(item) {
            Button(editTitle(for: item)) { edit(item) }
        }
        Divider()
        Button("Rename…") {
            newName = item.name
            renamingItem = item
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([library.fileURL(for: item)])
        }
        Divider()
        Button("Delete…", role: .destructive) { deletingItem = item }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let job = importer.jobs.first {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(importStatus(for: job))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if manager.pauseReason != nil || !manager.hasWallpaper {
                // Playing is the normal state and needs no label; only explain why nothing moves.
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                Text(manager.statusText)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if case .display(let displayID) = target, manager.hasOwnWallpaper(displayID) {
                Button("Same as All Displays") { manager.followAllDisplays(displayID) }
            }
            if currentID != nil {
                Button("Turn Off") { manager.setWallpaper(nil, for: target) }
            }
            if let item = selectedItem, canEdit(item) {
                Button(editTitle(for: item)) { edit(item) }
            }
            Button("Set as Wallpaper") {
                if let item = selectedItem {
                    apply(item)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedItem == nil || selectedItem?.id == currentID)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func importStatus(for job: ImportCoordinator.Job) -> String {
        let name = job.url.lastPathComponent
        let remaining = importer.jobs.count - 1
        if remaining > 0 {
            return String(format: NSLocalizedString("Adding “%@”… (%d more in queue)", comment: "Import progress"), name, remaining)
        }
        return String(format: NSLocalizedString("Adding “%@”…", comment: "Import progress"), name)
    }

    // MARK: - Actions

    private func apply(_ item: Wallpaper) {
        selection = item.id
        manager.setWallpaper(item.id, for: target)
    }

    /// Scenes open in the editor; a video or picture first becomes a scene with itself as the
    /// background. Other web wallpapers are someone else's pages and are shown as they are.
    private func canEdit(_ item: Wallpaper) -> Bool {
        item.kind != .web || library.isScene(item)
    }

    private func editTitle(for item: Wallpaper) -> LocalizedStringKey {
        item.kind == .web ? "Edit…" : "Edit as Scene…"
    }

    private func edit(_ item: Wallpaper) {
        if item.kind == .web {
            actions.editScene(item)
            return
        }
        do {
            let name = String(format: NSLocalizedString("%@ (scene)", comment: "Name of a scene made from a wallpaper"), item.name)
            let scene = try library.makeScene(from: item, named: name)
            selection = scene.id
            actions.editScene(scene)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func delete(_ item: Wallpaper) {
        if selection == item.id {
            selection = nil
        }
        library.remove([item.id])
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })
    }

    private var deletionTitle: String {
        String(format: NSLocalizedString("Delete “%@”?", comment: "Delete confirmation"), deletingItem?.name ?? "")
    }

    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url {
                urls.append(url)
            }
        }
        return urls
    }
}

// MARK: - Pieces

struct WallpaperTile: View {
    let item: Wallpaper
    let thumbnailURL: URL?
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detailsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .help(item.name)
    }

    private var preview: some View {
        Color.black
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let thumbnailURL, let image = ThumbnailCache.image(at: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.kind == .video ? "film" : item.kind == .web ? "square.3.layers.3d" : "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Text(item.sourceFormat)
                    if item.hasAudio {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title2)
                        .shadow(radius: 2)
                        .padding(6)
                        .help("Current wallpaper")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
    }
}

struct EmptyLibraryView: View {
    let addFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop GIFs and videos here")
                .font(.title2.weight(.semibold))
            Text("MP4, MOV, M4V, GIF, APNG, WebP, HEIC, PNG and JPEG are supported.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…", action: addFiles)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
        }
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
            .overlay {
                Label("Drop to Add", systemImage: "plus.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}
