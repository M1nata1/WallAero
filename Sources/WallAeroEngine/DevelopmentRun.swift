import Foundation

/// Started as a bare binary — `swift run`, an editor's Run button — the app has no bundle around
/// it and so no translations: every label comes out as its key. To macOS the binary's folder is
/// its bundle all the same, so the translations `scripts/build.sh` copies into the app are linked
/// into that folder here, before anything asks the bundle for them.
///
/// Info.plist is left where it is: with one next to the binary, code signing takes the whole
/// build folder for a bundle and the next build fails.
///
/// Only debug builds do this, the ones such a run makes: finding the package takes the path of
/// this file on the Mac that built it, which has no place in the app others download.
enum DevelopmentRun {
    static func prepare() {
        #if DEBUG
        guard let folder = executableURL?.deletingLastPathComponent(),
              // Inside an app the binary lies in Contents/MacOS and has all of this already.
              folder.lastPathComponent != "MacOS"
        else {
            return
        }
        // Sources/WallAeroEngine/DevelopmentRun.swift → the package → its Resources.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: resources.path) else { return }
        for name in names where name.hasSuffix(".lproj") {
            let link = folder.appendingPathComponent(name)
            // A link left by an earlier run points at the same place; one that exists is kept.
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) == nil, !files.fileExists(atPath: link.path) {
                try? files.createSymbolicLink(at: link, withDestinationURL: resources.appendingPathComponent(name))
            }
        }
        #endif
    }

    #if DEBUG
    /// Where the running binary is, asked of the system rather than of `Bundle.main`, which
    /// must not be looked at before the links are there.
    private static var executableURL: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    }
    #endif
}
