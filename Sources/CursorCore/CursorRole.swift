import Foundation

/// A macOS pointer role that can be themed, with the private CGS identifier the window server
/// knows it by, the Windows registry cursor names that map onto it (from an install.inf), and
/// the Windows file-name stems used as a fallback when there is no .inf.
public struct CursorRole: Hashable, Sendable {
    /// CGS cursor identifier, e.g. "com.apple.coregraphics.Arrow".
    public let id: String
    public let displayName: String
    /// Windows "Control Panel\Cursors" registry value names that map here (case-insensitive).
    public let windowsRegistryNames: [String]
    /// Lowercased Windows cursor file stems that map here, used when no install.inf is present.
    public let windowsAliases: [String]

    public init(id: String, displayName: String, windowsRegistryNames: [String], windowsAliases: [String]) {
        self.id = id
        self.displayName = displayName
        self.windowsRegistryNames = windowsRegistryNames
        self.windowsAliases = windowsAliases
    }

    public static let all: [CursorRole] = [
        CursorRole(id: "com.apple.coregraphics.Arrow", displayName: "Pointer",
                   windowsRegistryNames: ["Arrow"], windowsAliases: ["normal", "pointer", "arrow", "default"]),
        CursorRole(id: "com.apple.coregraphics.IBeam", displayName: "Text (I-beam)",
                   windowsRegistryNames: ["IBeam"], windowsAliases: ["text", "ibeam", "beam"]),
        CursorRole(id: "com.apple.cursor.2", displayName: "Link",
                   windowsRegistryNames: ["Hand"], windowsAliases: ["link", "hand", "pointinghand"]),
        CursorRole(id: "com.apple.cursor.13", displayName: "Pointing hand",
                   windowsRegistryNames: ["Hand"], windowsAliases: ["link", "hand", "pointinghand"]),
        CursorRole(id: "com.apple.coregraphics.Wait", displayName: "Busy (spinner)",
                   windowsRegistryNames: ["Wait"], windowsAliases: ["busy", "wait"]),
        CursorRole(id: "com.apple.cursor.4", displayName: "Working in background",
                   windowsRegistryNames: ["AppStarting"], windowsAliases: ["working", "appstarting", "work"]),
        CursorRole(id: "com.apple.coregraphics.Move", displayName: "Move",
                   windowsRegistryNames: ["SizeAll"], windowsAliases: ["move", "sizeall", "drag"]),
        CursorRole(id: "com.apple.cursor.11", displayName: "Closed hand",
                   windowsRegistryNames: ["SizeAll"], windowsAliases: ["move", "sizeall", "drag", "grab"]),
        CursorRole(id: "com.apple.cursor.12", displayName: "Open hand",
                   windowsRegistryNames: ["SizeAll"], windowsAliases: ["move", "sizeall", "drag", "grab"]),
        CursorRole(id: "com.apple.cursor.7", displayName: "Crosshair",
                   windowsRegistryNames: ["Crosshair", "precisionhair"], windowsAliases: ["precision", "crosshair", "cross"]),
        CursorRole(id: "com.apple.cursor.3", displayName: "Not allowed",
                   windowsRegistryNames: ["No"], windowsAliases: ["unavailable", "no", "forbidden", "notallowed"]),
        CursorRole(id: "com.apple.cursor.23", displayName: "Resize ↕",
                   windowsRegistryNames: ["SizeNS"], windowsAliases: ["vertical", "sizens", "ns", "resizenorthsouth"]),
        CursorRole(id: "com.apple.cursor.19", displayName: "Resize ↔",
                   windowsRegistryNames: ["SizeWE"], windowsAliases: ["horizontal", "sizewe", "we", "resizeeastwest"]),
        CursorRole(id: "com.apple.cursor.34", displayName: "Resize ⤡",
                   windowsRegistryNames: ["SizeNWSE"], windowsAliases: ["diagonal1", "sizenwse", "nwse"]),
        CursorRole(id: "com.apple.cursor.30", displayName: "Resize ⤢",
                   windowsRegistryNames: ["SizeNESW"], windowsAliases: ["diagonal2", "sizenesw", "nesw"]),
        CursorRole(id: "com.apple.cursor.40", displayName: "Help",
                   windowsRegistryNames: ["Help"], windowsAliases: ["help"]),
    ] + variants

    /// More macOS cursors themed from the same Windows cursors: the arrow and I-beam macOS 26
    /// actually shows, the vertical-text I-beam, one-way resize arrows, the window-edge and corner
    /// resize cursors macOS 15 uses (and the Dock divider), AppKit's own crosshair and, since
    /// Windows packs have no camera, the camera shown over a window while taking a screenshot.
    /// Listed after the primary roles so `matching` still returns those first.
    ///
    /// The area-selection crosshair of ⌘⇧4 cannot be themed: `screencapture` draws it itself,
    /// from an image built into the tool, merged with the coordinates into one cursor that it
    /// replaces on every mouse move. The system's "screenshot selection" cursors (7 and 8) are
    /// themed all the same for anything that still uses them.
    private static let variants: [CursorRole] = {
        let pointer = (["Arrow"], ["normal", "pointer", "arrow", "default"])
        let text = (["IBeam"], ["text", "ibeam", "beam"])
        // macOS 26 draws the arrow and I-beam from these and ignores the older Arrow and IBeam
        // names; earlier systems do not have them, so registering them there changes nothing.
        let macOS26 = [
            CursorRole(id: "com.apple.coregraphics.ArrowS", displayName: "Pointer (macOS 26)",
                       windowsRegistryNames: pointer.0, windowsAliases: pointer.1),
            CursorRole(id: "com.apple.coregraphics.IBeamS", displayName: "Text (macOS 26)",
                       windowsRegistryNames: text.0, windowsAliases: text.1),
        ]
        let vertical = (["SizeNS"], ["vertical", "sizens", "ns", "resizenorthsouth"])
        let horizontal = (["SizeWE"], ["horizontal", "sizewe", "we", "resizeeastwest"])
        let diagonal1 = (["SizeNWSE"], ["diagonal1", "sizenwse", "nwse"])
        let diagonal2 = (["SizeNESW"], ["diagonal2", "sizenesw", "nesw"])
        let crosshair = (["Crosshair", "precisionhair"], ["precision", "crosshair", "cross"])
        let move = (["SizeAll"], ["move", "sizeall", "drag"])
        let table: [(Int, String, ([String], [String]))] = [
            (26, "Text (vertical)", text),
            (21, "Resize ↑", vertical), (22, "Resize ↓", vertical),
            (31, "Window edge ↑", vertical), (32, "Window edge ↕", vertical), (36, "Window edge ↓", vertical),
            (17, "Resize ←", horizontal), (18, "Resize →", horizontal),
            (27, "Window edge →", horizontal), (28, "Window edge ↔", horizontal), (38, "Window edge ←", horizontal),
            (33, "Window corner ↖", diagonal1), (35, "Window corner ↘", diagonal1),
            (29, "Window corner ↗", diagonal2), (37, "Window corner ↙", diagonal2),
            (20, "Crosshair (AppKit)", crosshair),
            (8, "Screenshot selection (to clipboard)", crosshair),
            // The camera shown over a window after ⌘⇧4 and Space; 10 is its copy-to-clipboard twin.
            (9, "Screenshot window", crosshair), (10, "Screenshot window (to clipboard)", crosshair),
            (39, "Move (all directions)", move),
        ]
        return macOS26 + table.map { id, name, names in
            CursorRole(id: "com.apple.cursor.\(id)", displayName: name,
                       windowsRegistryNames: names.0, windowsAliases: names.1)
        }
    }()

    /// The first role a file stem belongs to, e.g. "SizeAll" → Move.
    public static func matching(fileStem: String) -> CursorRole? {
        matchingRoles(fileStem: fileStem).first
    }

    /// Every role a file stem maps to. One Windows cursor can cover several macOS roles — e.g.
    /// "Link" themes both the link arrow and the pointing hand.
    public static func matchingRoles(fileStem: String) -> [CursorRole] {
        let key = fileStem.lowercased().replacingOccurrences(of: " ", with: "")
        return all.filter { $0.windowsAliases.contains(key) }
    }

    /// Every role a Windows registry cursor name (from install.inf) maps to.
    public static func roles(forRegistryName name: String) -> [CursorRole] {
        let key = name.lowercased()
        return all.filter { $0.windowsRegistryNames.contains { $0.lowercased() == key } }
    }
}
