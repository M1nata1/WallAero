// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallAeroEngine",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WallAeroEngine", targets: ["WallAeroEngine"])
    ],
    targets: [
        // Media import, conversion and the wallpaper library. No UI code.
        .target(
            name: "WallpaperCore",
            path: "Sources/WallpaperCore"
        ),
        // Thin C wrapper over the private CoreGraphics cursor API (CGS).
        .target(
            name: "CGSCursor",
            path: "Sources/CGSCursor",
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        // Windows .ani/.cur decoding and the system-wide cursor theme engine.
        .target(
            name: "CursorCore",
            dependencies: ["CGSCursor"],
            path: "Sources/CursorCore"
        ),
        // The menu bar app: desktop windows, playback engine and SwiftUI screens.
        .executableTarget(
            name: "WallAeroEngine",
            dependencies: ["WallpaperCore", "CursorCore"],
            path: "Sources/WallAeroEngine"
        ),
        // Command-line helper to apply or reset a cursor theme, reusing the app's engine.
        .executableTarget(
            name: "cursorctl",
            dependencies: ["CursorCore"],
            path: "Sources/cursorctl"
        ),
        .testTarget(
            name: "WallpaperCoreTests",
            dependencies: ["WallpaperCore"],
            path: "Tests/WallpaperCoreTests"
        ),
        .testTarget(
            name: "CursorCoreTests",
            dependencies: ["CursorCore"],
            path: "Tests/CursorCoreTests"
        ),
    ]
)
