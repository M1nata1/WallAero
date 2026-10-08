import Foundation

/// A folder that holds a web wallpaper: a page to show, and for wallpapers made for Wallpaper
/// Engine also the title, the preview picture and the settings from their `project.json`.
public struct WebProject: Equatable, Sendable {
    public let folder: URL
    /// The page, relative to the folder; usually `index.html`.
    public let entryFile: String
    public let title: String?
    /// A preview picture that came with the wallpaper, relative to the folder.
    public let previewFile: String?
    /// The wallpaper's own settings — Wallpaper Engine's `general.properties` — as JSON text, in
    /// the form the page's `wallpaperPropertyListener.applyUserProperties` expects.
    public let userPropertiesJSON: String?

    public var entryURL: URL { folder.appendingPathComponent(entryFile) }

    /// Whether the page is one of our own scenes, which the editor can open.
    public var isScene: Bool { SceneProject.isScene(folder) }

    /// Reads the folder; nil when there is no page in it to show.
    public init?(folder: URL) {
        let fileManager = FileManager.default
        var entry: String?
        var title: String?
        var preview: String?
        var properties: String?

        if let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
           let project = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Wallpaper Engine also keeps scenes and videos in such folders; only pages can be shown.
            if let type = project["type"] as? String, type.lowercased() != "web" {
                return nil
            }
            entry = project["file"] as? String
            title = (project["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            preview = project["preview"] as? String
            if let general = project["general"] as? [String: Any], let values = general["properties"] as? [String: Any],
               !values.isEmpty, let json = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
                properties = String(decoding: json, as: UTF8.self)
            }
        }

        func isPage(_ name: String) -> Bool {
            ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
                && fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        if SceneProject.isScene(folder) {
            // A scene's page is generated; it is written when missing, see `SceneProject`.
            entry = SceneProject.entryFileName
        } else if entry.map(isPage) != true {
            let pages = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isPage).sorted()
            // A page called index.html is the one to show; failing that, a folder with a single page.
            entry = pages.first { $0.lowercased() == "index.html" } ?? (pages.count == 1 ? pages[0] : nil)
        }
        guard let entry else { return nil }

        self.folder = folder
        entryFile = entry
        self.title = title
        previewFile = preview.flatMap { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) ? $0 : nil }
        userPropertiesJSON = properties
    }
}
