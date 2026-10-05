import CoreGraphics
import XCTest
@testable import CursorCore

/// Exercises the real system cursor path (apply → read back → reset → read back) against the
/// user's live session, so it only runs when explicitly asked for:
///
///     WALLAERO_LIVE_CURSOR_TEST=1 swift test --filter SystemCursorLiveTests
///
/// It changes only the I-beam cursor and always restores it.
@MainActor
final class SystemCursorLiveTests: XCTestCase {
    private let ibeam = "com.apple.coregraphics.IBeam"
    private let packFolder = URL(fileURLWithPath:
        "/Users/fadevec/Documents/Personalization/Cursors/Hatsune Miku Cursor")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WALLAERO_LIVE_CURSOR_TEST"] == "1",
                          "set WALLAERO_LIVE_CURSOR_TEST=1 to run the live cursor test")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: packFolder.path), "cursor pack not present")
    }

    func testApplyThenResetRestoresTheIBeam() throws {
        let controller = SystemCursorController(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("WallAeroEngineCursorTest-\(UUID().uuidString)"))

        let original = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(
            contentsOf: packFolder.appendingPathComponent("Text.ani")))
        let role = try XCTUnwrap(CursorRole.all.first { $0.id == ibeam })
        let theme = CursorTheme(
            name: "Test",
            assignments: [CursorAssignment(role: role, sourceURL: packFolder, decoded: decoded)],
            unmatchedFiles: []
        )

        let result = controller.apply(theme, pointSize: 24)
        XCTAssertEqual(result.applied, ["Text (I-beam)"])
        XCTAssertTrue(controller.isApplied)
        let applied = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        XCTAssertEqual(max(applied.width, applied.height), 24, accuracy: 0.5)

        controller.reset()
        XCTAssertFalse(controller.isApplied)
        let restored = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        XCTAssertEqual(restored.width, original.width, accuracy: 0.5)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.5)
    }
}

/// Also runs against the window server, but under a made-up cursor name that nothing on screen
/// ever uses, so it is safe in any session and runs with the other tests.
@MainActor
final class SystemCursorKeepTests: XCTestCase {
    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallAeroEngineCursorTest-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPutsBackAReplacedCursorAndResetRemovesIt() throws {
        let role = CursorRole(id: "com.fadevec.wallaeroengine.test.\(UUID().uuidString)", displayName: "Test",
                              windowsRegistryNames: [], windowsAliases: [])
        let frames = (0..<4).map { _ in CursorFixtures.tinyImage() }
        let decoded = DecodedCursor(frames: frames, frameDurations: Array(repeating: 0.1, count: 4),
                                    hotSpot: CGPoint(x: 1, y: 1), pixelSize: CGSize(width: 2, height: 2))
        let theme = CursorTheme(name: "Test", assignments: [CursorAssignment(role: role, sourceURL: URL(fileURLWithPath: "/"), decoded: decoded)],
                                unmatchedFiles: [])
        let app = SystemCursorController(rootURL: temporaryFolder())
        XCTAssertEqual(app.apply(theme, pointSize: 28).applied, ["Test"])
        XCTAssertTrue(app.replacedAssignments(in: theme, pointSize: 28).isEmpty)

        // Something else registers its own cursor under that name, as macOS may do behind our back.
        SystemCursorController(rootURL: temporaryFolder()).apply(theme, pointSize: 20)
        XCTAssertEqual(app.replacedAssignments(in: theme, pointSize: 28).map(\.role.id), [role.id])

        XCTAssertTrue(app.restoreReplaced(theme, pointSize: 28, ignoring: [role.id]).restored.isEmpty, "ignored roles stay as they are")
        XCTAssertEqual(app.restoreReplaced(theme, pointSize: 28).restored, ["Test"])
        XCTAssertTrue(app.replacedAssignments(in: theme, pointSize: 28).isEmpty)
        XCTAssertEqual(try XCTUnwrap(app.registeredSize(roleID: role.id)).width, 28, accuracy: 0.5)

        // The name did not exist before the theme, so Reset must remove it, not leave ours behind.
        app.reset()
        XCTAssertNil(app.registeredSize(roleID: role.id))
    }
}
