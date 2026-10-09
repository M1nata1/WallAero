import AppKit
import SwiftUI
import WallpaperCore

/// The row above the wallpapers that narrows the library down: a search field, and a button
/// that drops down the library's tags to tick.
struct LibraryFilterBar: View {
    @Binding var searchText: String
    let groups: [TagGroup]
    @Binding var selection: Set<String>
    @Binding var showsTags: Bool

    var body: some View {
        HStack(spacing: 12) {
            SearchField(text: $searchText)
                .frame(width: 200)
            Button {
                showsTags.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                    // How many are ticked shows on the button, so a filter is not forgotten.
                    Text("Tags") + Text(verbatim: selection.isEmpty ? "" : " · \(selection.count)")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .pressedButtonStyle(!selection.isEmpty)
            .disabled(groups.isEmpty)
            .popover(isPresented: $showsTags, arrowEdge: .bottom) {
                TagChecklist(groups: groups, selection: $selection)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// The library's tags with a checkbox each, under the names of their categories. Of one
/// category any ticked tag will do; of several categories a wallpaper needs one from each.
struct TagChecklist: View {
    let groups: [TagGroup]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(groups) { group in
                        if groups.namesCategories {
                            group.title
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, group == groups.first ? 0 : 7)
                        }
                        ForEach(group.tags, id: \.self) { tag in
                            Toggle(isOn: isTicked(tag)) {
                                Text(verbatim: tag)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxHeight: 360)
            Divider()
            Button("Reset") {
                selection = []
            }
            .disabled(selection.isEmpty)
            .padding(10)
        }
        .frame(minWidth: 220)
    }

    private func isTicked(_ tag: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(tag) },
            set: { isOn in
                if isOn {
                    selection.insert(tag)
                } else {
                    selection.remove(tag)
                }
            }
        )
    }
}

extension TagGroup {
    /// What the group is called in a list.
    var title: Text {
        category.map { Text(verbatim: $0) } ?? Text("No Category")
    }
}

extension [TagGroup] {
    /// Whether a list of the groups needs their names: not while no tag has a category.
    var namesCategories: Bool {
        contains { $0.category != nil }
    }
}

/// The system's own search field: every version of macOS draws it its way, with its own
/// placeholder and the button that clears it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        // The action is what the clearing button sends; typing is told to the delegate.
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                changed(field)
            }
        }

        @objc func changed(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}

/// The tags of one wallpaper, in its settings. A tag opens a menu that puts it into a category
/// or takes it off; a new one is typed, and one other wallpapers have is picked from a menu.
struct TagEditor: View {
    @EnvironmentObject private var library: WallpaperLibrary
    let item: Wallpaper

    @State private var draft = ""
    /// The tag a new category is being named for.
    @State private var categorizedTag: String?
    @State private var newCategory = ""

    private var tags: [String] { item.tagList }

    /// The library's tags this wallpaper does not have, by category.
    private var suggestions: [TagGroup] {
        library.tagGroups.compactMap { group in
            let others = group.tags.filter { !tags.contains($0) }
            return others.isEmpty ? nil : TagGroup(category: group.category, tags: others)
        }
    }

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    chip(for: tag)
                }
            }
            .padding(.vertical, 2)
        }
        HStack(spacing: 8) {
            TextField("New Tag", text: $draft, prompt: Text("New Tag"))
                .labelsHidden()
                .onSubmit(addDraft)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions) { group in
                        Section {
                            ForEach(group.tags, id: \.self) { tag in
                                Button {
                                    library.setTags(tags + [tag], for: item.id)
                                } label: {
                                    Text(verbatim: tag)
                                }
                            }
                        } header: {
                            if suggestions.namesCategories {
                                group.title
                            }
                        }
                    }
                } label: {
                    Image(systemName: "tag")
                }
                .fixedSize()
                .help("Tags")
            }
        }
        .alert("New Category", isPresented: isNamingCategory) {
            TextField("Category", text: $newCategory)
            Button("Add") {
                if let tag = categorizedTag {
                    library.setCategory(newCategory, ofTag: tag)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(for tag: String) -> some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Category", selection: category(of: tag)) {
                    Text("No Category").tag(String?.none)
                    ForEach(library.allCategories, id: \.self) { category in
                        Text(verbatim: category).tag(String?.some(category))
                    }
                }
                .pickerStyle(.inline)
                Button("New Category…") {
                    newCategory = ""
                    categorizedTag = tag
                }
                Divider()
                Button("Remove Tag", role: .destructive) {
                    remove(tag)
                }
            } label: {
                Text(verbatim: tag)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                remove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove Tag")
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private func category(of tag: String) -> Binding<String?> {
        Binding(get: { library.category(of: tag) }, set: { library.setCategory($0, ofTag: tag) })
    }

    private var isNamingCategory: Binding<Bool> {
        Binding(get: { categorizedTag != nil }, set: { if !$0 { categorizedTag = nil } })
    }

    private func remove(_ tag: String) {
        library.setTags(tags.filter { $0 != tag }, for: item.id)
    }

    private func addDraft() {
        // Several at once may be typed with commas between them.
        let typed = draft.split(separator: ",").map(String.init)
        draft = ""
        library.setTags(tags + typed, for: item.id)
    }
}

/// Lays views out in rows from the leading edge, starting a new row when the next view does not
/// fit in the width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arranged = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arranged.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
