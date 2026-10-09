import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

struct LibraryActions {
    var addFiles: () -> Void
    /// Opens a wallpaper in the scene editor; a video or a picture becomes a scene first.
    var edit: (Wallpaper) -> Void = { _ in }
}

extension WallpaperLibrary {
    /// Scenes open in the editor, and a video or picture can become one. Other web wallpapers
    /// are someone else's pages and are shown as they are.
    func canEdit(_ item: Wallpaper) -> Bool {
        item.kind != .web || isScene(item)
    }

    func editTitle(for item: Wallpaper) -> LocalizedStringKey {
        item.kind == .web ? "Edit…" : "Edit as Scene…"
    }
}

/// The app's main window: the library, with the settings at its side when they are asked for.
struct MainView: View {
    @EnvironmentObject private var state: MainWindowState
    let actions: LibraryActions

    var body: some View {
        if #available(macOS 14.0, *) {
            // The system's own side panel: it looks the way the Mac's version of macOS has them.
            LibraryView(actions: actions)
                .inspector(isPresented: $state.showsSettings) {
                    SettingsPanel(edit: actions.edit)
                        .inspectorColumnWidth(MainWindowState.settingsWidth)
                        .toolbar {
                            Spacer()
                            SettingsToggle(isOn: $state.showsSettings)
                        }
                }
        } else {
            HStack(spacing: 0) {
                LibraryView(actions: actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.showsSettings {
                    Divider()
                    SettingsPanel(edit: actions.edit)
                        .frame(width: MainWindowState.settingsWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
    }
}

/// The button that shows the settings at the side of the window; it stays pressed while they
/// are open.
struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label("Settings", systemImage: "gearshape")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("Settings")
    }
}

struct LibraryView: View {
    /// The least room the library needs, in points.
    static let minimumSize = CGSize(width: 640, height: 440)
    /// How wide a wallpaper's picture is. It is the same at any width of the library: showing
    /// and hiding the settings changes how many fit in a row, never their size.
    static let tileWidth: CGFloat = 216

    @EnvironmentObject private var library: WallpaperLibrary
    @EnvironmentObject private var manager: WallpaperManager
    @EnvironmentObject private var importer: ImportCoordinator
    @EnvironmentObject private var state: MainWindowState
    let actions: LibraryActions

    @State private var target: DisplayTarget = .all
    @State private var isDropTargeted = false
    @State private var renamingItem: Wallpaper?
    @State private var newName = ""
    @State private var deletingItem: Wallpaper?
    @State private var taggingItem: Wallpaper?
    @State private var newTag = ""

    /// Kept in the window's state: the settings at the side are for the selected wallpaper.
    private var selection: UUID? {
        get { state.selection }
        nonmutating set { state.selection = newValue }
    }

    private var selectedItem: Wallpaper? { selection.flatMap(library.item(withID:)) }
    /// The wallpapers the search and the ticked tags leave.
    private var shownItems: [Wallpaper] {
        // The ticked tags by category: within one any will do, between them each counts.
        let groups = Dictionary(grouping: state.selectedTags) { library.category(of: $0) ?? "" }.values.map(Set.init)
        return library.items.filter { $0.matches(search: state.searchText, tagGroups: groups) }
    }
    private var currentID: UUID? { manager.wallpaperID(for: target) }

    var body: some View {
        layout
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
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
            .onChange(of: library.allTags) { tags in
                // A tag taken off its last wallpaper is gone from the list, and from the filter.
                state.selectedTags.formIntersection(tags)
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
            .alert("New Tag", isPresented: isTagging) {
                TextField("Tag", text: $newTag)
                Button("Add") {
                    if let item = taggingItem.flatMap({ library.item(withID: $0.id) }) {
                        library.setTags(item.tagList + [newTag], for: item.id)
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

    // MARK: - Layout

    /// The buttons are the window's toolbar where the system takes one from the content
    /// (macOS 14); before that they are a line at the top of the window.
    @ViewBuilder
    private var layout: some View {
        if #available(macOS 14.0, *) {
            filterable
                .bottomBar { footer }
                .toolbar {
                    if manager.displays.count > 1 {
                        ToolbarItem(placement: .navigation) { displayPicker }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        pauseButton
                        addButton
                    }
                }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                filterable
                Divider()
                footer
            }
        }
    }

    /// The wallpapers under the row that searches and filters them.
    private var filterable: some View {
        droppable.topBar {
            LibraryFilterBar(searchText: $state.searchText, groups: library.tagGroups,
                             selection: $state.selectedTags, showsTags: $state.showsTagFilter)
        }
    }

    /// The wallpapers, taking files dropped on them.
    private var droppable: some View {
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if manager.displays.count > 1 {
                displayPicker
            }
            Spacer()
            pauseButton
            addButton
            SettingsToggle(isOn: $state.showsSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var displayPicker: some View {
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

    private var pauseButton: some View {
        let (title, symbol): (LocalizedStringKey, String) = manager.isPausedByUser ? ("Resume", "play.fill") : ("Pause", "pause.fill")
        return Button {
            manager.isPausedByUser.toggle()
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(!manager.hasWallpaper)
        // In the toolbar the buttons are pictures only; their names show when the pointer rests.
        .help(title)
    }

    private var addButton: some View {
        Button(action: actions.addFiles) {
            Label("Add…", systemImage: "plus")
        }
        .help("Add…")
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            EmptyLibraryView(addFiles: actions.addFiles)
        } else if shownItems.isEmpty {
            NothingFoundView(searchText: state.searchText)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth), spacing: 16)],
                          alignment: .leading, spacing: 20) {
                    ForEach(shownItems) { item in
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
        if library.canEdit(item) {
            Button(library.editTitle(for: item)) { actions.edit(item) }
        }
        Divider()
        Button("Rename…") {
            newName = item.name
            renamingItem = item
        }
        Menu("Tags") {
            let groups = library.tagGroups
            ForEach(groups) { group in
                Section {
                    ForEach(group.tags, id: \.self) { tag in
                        Toggle(isOn: hasTag(tag, item)) {
                            Text(verbatim: tag)
                        }
                    }
                } header: {
                    if groups.namesCategories {
                        group.title
                    }
                }
            }
            if !groups.isEmpty {
                Divider()
            }
            Button("New Tag…") {
                newTag = ""
                taggingItem = item
            }
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
                    .barButtonStyle()
            }
            if currentID != nil {
                Button("Turn Off") { manager.setWallpaper(nil, for: target) }
                    .barButtonStyle()
            }
            Button("Set as Wallpaper") {
                if let item = selectedItem {
                    apply(item)
                }
            }
            .keyboardShortcut(.defaultAction)
            .barButtonStyle(isMainAction: true)
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

    private func delete(_ item: Wallpaper) {
        if selection == item.id {
            selection = nil
        }
        library.remove([item.id])
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
    }

    private var isTagging: Binding<Bool> {
        Binding(get: { taggingItem != nil }, set: { if !$0 { taggingItem = nil } })
    }

    /// Whether a wallpaper has a tag; setting it gives the tag or takes it off.
    private func hasTag(_ tag: String, _ item: Wallpaper) -> Binding<Bool> {
        Binding(
            get: { library.item(withID: item.id)?.tagList.contains(tag) ?? false },
            set: { isOn in
                let tags = library.item(withID: item.id)?.tagList ?? []
                library.setTags(isOn ? tags + [tag] : tags.filter { $0 != tag }, for: item.id)
            }
        )
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
            .clipShape(RoundedRectangle(cornerRadius: SystemLook.tileCornerRadius, style: .continuous))
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
                RoundedRectangle(cornerRadius: SystemLook.tileCornerRadius, style: .continuous)
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
            RoundedRectangle(cornerRadius: SystemLook.frameCornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
        }
    }
}

/// Shown in place of the wallpapers when the search and the ticked tags leave none.
struct NothingFoundView: View {
    let searchText: String

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                // The system's own words for it, naming what was typed if anything was.
                ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                Text("Nothing Found")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SystemLook.frameCornerRadius - 4, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: SystemLook.frameCornerRadius - 4, style: .continuous)
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
