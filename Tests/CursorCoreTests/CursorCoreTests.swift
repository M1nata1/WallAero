import CoreGraphics
import ImageIO
import XCTest
@testable import CursorCore

final class CursorImageDecoderTests: XCTestCase {
    func testDecodesASingleCursorWithItsHotspot() throws {
        let cur = CursorFixtures.cur(side: 32, hotspot: (1, 2))
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(data: Data(cur)))
        XCTAssertEqual(decoded.frames.count, 1)
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(decoded.hotSpot, CGPoint(x: 1, y: 2))
        XCTAssertFalse(decoded.isAnimated)
    }

    func testDecodesAnimatedAniWithPerFrameDurations() throws {
        let ani = CursorFixtures.ani(side: 32, hotspot: (2, 0), ratesInJiffies: [3, 6, 9])
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(data: Data(ani)))
        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertTrue(decoded.isAnimated)
        XCTAssertEqual(decoded.hotSpot, CGPoint(x: 2, y: 0))
        XCTAssertEqual(decoded.frameDurations, [3.0 / 60, 6.0 / 60, 9.0 / 60])
    }

    func testUsesDefaultRateWhenNoRateChunk() throws {
        let ani = CursorFixtures.ani(side: 32, hotspot: (0, 0), ratesInJiffies: nil, defaultJiffies: 5)
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(data: Data(ani)))
        XCTAssertEqual(decoded.frameDurations, Array(repeating: 5.0 / 60, count: decoded.frames.count))
    }

    func testPicksTheLargestResolutionInAFrame() throws {
        // HD packs store several sizes per frame; the largest wins, with its own hotspot.
        let cur = CursorFixtures.multiCur(entries: [(side: 32, hotspot: (7, 3)), (side: 48, hotspot: (11, 5))])
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(data: Data(cur)))
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 48, height: 48))
        XCTAssertEqual(decoded.hotSpot, CGPoint(x: 11, y: 5))
    }

    func testRejectsGarbage() {
        XCTAssertNil(CursorImageDecoder.decode(data: Data([0, 1, 2, 3, 4, 5, 6, 7])))
    }
}

final class FrameLimitTests: XCTestCase {
    func testLongAnimationsAreResampledToTheFrameLimit() {
        // e.g. Crystal Clear's pointer: 60 steps, which the window server would reject.
        let frames = (0..<60).map { _ in CursorFixtures.tinyImage() }
        let fitted = SystemCursorController.fitToFrameLimit(frames, durations: Array(repeating: 1.0 / 30, count: 60))
        XCTAssertEqual(fitted.frames.count, SystemCursorController.maximumFrameCount)
        XCTAssertEqual(fitted.frameDuration, 2.0 / 24, accuracy: 0.0001, "the 2 s loop length is kept")
        XCTAssertTrue(fitted.frames.first === frames[1])
        XCTAssertTrue(fitted.frames.last === frames[58])
    }

    func testShortAnimationsKeepTheirFrames() {
        let frames = (0..<8).map { _ in CursorFixtures.tinyImage() }
        let fitted = SystemCursorController.fitToFrameLimit(frames, durations: Array(repeating: 0.1, count: 8))
        XCTAssertEqual(fitted.frames.count, 8)
        XCTAssertEqual(fitted.frameDuration, 0.1, accuracy: 0.0001)
    }
}

final class CursorRoleTests: XCTestCase {
    func testWindowsNamesMapToMacRoles() {
        XCTAssertEqual(CursorRole.matching(fileStem: "Normal")?.id, "com.apple.coregraphics.Arrow")
        XCTAssertEqual(CursorRole.matching(fileStem: "Text")?.id, "com.apple.coregraphics.IBeam")
        XCTAssertEqual(CursorRole.matching(fileStem: "SizeAll")?.id, "com.apple.coregraphics.Move")
        XCTAssertEqual(CursorRole.matching(fileStem: "Link")?.id, "com.apple.cursor.2")
        XCTAssertEqual(CursorRole.matching(fileStem: "Diagonal2")?.id, "com.apple.cursor.30")
        XCTAssertNil(CursorRole.matching(fileStem: "Pin"))
    }
}

final class WindowsCursorInfTests: XCTestCase {
    private let sampleInf = """
    [Version]
    signature="$CHICAGO$"

    [Wreg]
    HKCU,"Control Panel\\Cursors",,0x00020000,"%SCHEME_NAME%"
    HKCU,"Control Panel\\Cursors",Arrow,0x00020000,"%10%\\%CUR_DIR%\\%pointer%"
    HKCU,"Control Panel\\Cursors",Hand,0x00020000,"%10%\\%CUR_DIR%\\%link%"
    HKCU,"Control Panel\\Cursors",SizeAll,0x00020000,"%10%\\%CUR_DIR%\\%move%"
    HKCU,"Control Panel\\Cursors",NWPen,0x00020000,"%10%\\%CUR_DIR%\\%hand%"
    HKLM,"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Runonce\\Setup\\","",,"rundll32.exe ..."

    [Strings]
    CUR_DIR     = "Cursors\\Pack"
    SCHEME_NAME = "Pack"
    pointer = "MyPointer.ani"
    link    = "MyLink.ani"
    move    = "MyMove.ani"
    hand    = "MyHandwriting.ani"
    """

    func testParsesRegistryNamesToFiles() {
        let entries = WindowsCursorInf.parse(sampleInf)
        func file(_ name: String) -> String? { entries.first { $0.registryName == name }?.fileName }
        XCTAssertEqual(file("Arrow"), "MyPointer.ani")
        XCTAssertEqual(file("Hand"), "MyLink.ani")
        XCTAssertEqual(file("SizeAll"), "MyMove.ani")
        XCTAssertEqual(file("NWPen"), "MyHandwriting.ani")
        // The scheme-name line and the RunOnce line are not cursor entries.
        XCTAssertEqual(entries.count, 4)
    }

    func testParsesSchemesListWhenNoWregSection() {
        // Some packs only ship the ordered "Schemes" list, with no per-role [Wreg] lines.
        let files = "pointer,help,work,busy,cross,text,hand,na,vert,horz,d1,d2,move,alt,link"
        let paths = files.components(separatedBy: ",").map { "%10%\\%CUR_DIR%\\%\($0)%" }.joined(separator: ",")
        var strings = ""
        for name in files.components(separatedBy: ",") { strings += "\(name) = \"\(name.uppercased()).ani\"\n" }
        let inf = """
        [Scheme.Reg]
        HKCU,"Control Panel\\Cursors\\Schemes","%SCHEME_NAME%",,"\(paths)"

        [Strings]
        \(strings)
        """
        let entries = WindowsCursorInf.parse(inf)
        func file(_ reg: String) -> String? { entries.first { $0.registryName == reg }?.fileName }
        XCTAssertEqual(file("Arrow"), "POINTER.ani")   // position 0
        XCTAssertEqual(file("IBeam"), "TEXT.ani")      // position 5
        XCTAssertEqual(file("NWPen"), "HAND.ani")      // position 6 (handwriting)
        XCTAssertEqual(file("SizeAll"), "MOVE.ani")    // position 12
        XCTAssertEqual(file("Hand"), "LINK.ani")       // position 14 (clickable link)
    }

    func testRegistryNamesMapToMacRoles() {
        // macOS 26 shows the arrow and I-beam from the "S" names; the older names stay for earlier systems.
        XCTAssertEqual(CursorRole.roles(forRegistryName: "Arrow").map(\.id),
                       ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS"])
        XCTAssertEqual(CursorRole.roles(forRegistryName: "IBeam").map(\.id),
                       ["com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamS", "com.apple.cursor.26"])
        XCTAssertEqual(CursorRole.roles(forRegistryName: "Wait").map(\.id), ["com.apple.coregraphics.Wait"])
        // "Hand" (the clickable pointer in Windows) themes both link and pointing hand on macOS.
        XCTAssertEqual(CursorRole.roles(forRegistryName: "Hand").map(\.id), ["com.apple.cursor.2", "com.apple.cursor.13"])
        XCTAssertTrue(CursorRole.roles(forRegistryName: "NWPen").isEmpty)
        // The vertical resize cursor also themes macOS's window-edge one, used by the Dock divider.
        let vertical = CursorRole.roles(forRegistryName: "SizeNS").map(\.id)
        XCTAssertEqual(vertical.first, "com.apple.cursor.23")
        XCTAssertTrue(vertical.contains("com.apple.cursor.32"))
        // The crosshair also stands in for the window-capture cameras (9, 10): Windows packs have
        // none. 7 and 8 are the system's screenshot-selection cursors, which ⌘⇧4 no longer shows.
        XCTAssertEqual(CursorRole.roles(forRegistryName: "Crosshair").map(\.id),
                       ["com.apple.cursor.7", "com.apple.cursor.20", "com.apple.cursor.8", "com.apple.cursor.9", "com.apple.cursor.10"])
    }
}

/// Runs only on the machine that has the real cursor pack; skipped elsewhere.
final class RealCursorPackTests: XCTestCase {
    private let folder = URL(fileURLWithPath:
        "/Users/fadevec/Documents/Personalization/Cursors/Hatsune Miku Cursor")

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "cursor pack not present")
    }

    func testDecodesTheMikuNormalCursor() throws {
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(contentsOf: folder.appendingPathComponent("Normal.ani")))
        XCTAssertEqual(decoded.frames.count, 8)
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 64, height: 64))
        XCTAssertTrue(decoded.frameDurations.allSatisfy { abs($0 - 5.0 / 60) < 0.001 })
    }

    func testLoadsTheWholePackViaInstallInf() {
        let theme = CursorTheme.load(fromFolder: folder)
        XCTAssertTrue(theme.usedInf, "the pack ships install.inf, which should drive the mapping")
        let ids = Set(theme.assignments.map(\.role.id))
        XCTAssertTrue(ids.contains("com.apple.coregraphics.Arrow"))
        XCTAssertTrue(ids.contains("com.apple.coregraphics.IBeam"))
        XCTAssertTrue(ids.contains("com.apple.cursor.13"), "Hand → pointing hand")
        XCTAssertGreaterThanOrEqual(theme.assignments.count, 14)
        // Handwriting (NWPen), Alternate (UpArrow), Person and Pin have no macOS equivalent.
        let unmatched = Set(theme.unmatchedFiles.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertTrue(unmatched.contains("Handwriting"))
        XCTAssertTrue(unmatched.contains("Pin"))
    }
}

// MARK: - Fixtures

enum CursorFixtures {
    /// A distinct 2×2 image, for tests that only care about frame identity.
    static func tinyImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A `.cur` holding several resolutions of the same frame, like HD cursor packs.
    static func multiCur(entries: [(side: Int, hotspot: (Int, Int))]) -> [UInt8] {
        let payloads = entries.map { dib(side: $0.side) }
        var header: [UInt8] = []
        appendU16(&header, 0)
        appendU16(&header, 2)            // type: cursor
        appendU16(&header, entries.count)
        var offset = 6 + 16 * entries.count
        for (entry, payload) in zip(entries, payloads) {
            header += [UInt8(entry.side), UInt8(entry.side), 0, 0]
            appendU16(&header, entry.hotspot.0); appendU16(&header, entry.hotspot.1)
            appendU32(&header, payload.count)
            appendU32(&header, offset)
            offset += payload.count
        }
        return header + payloads.flatMap { $0 }
    }

    /// A minimal 32-bit BMP `.cur` of a solid square with the given hotspot. ImageIO's icon
    /// reader rejects very small frames, so tests use a realistic 32×32.
    static func cur(side n: Int, hotspot: (Int, Int)) -> [UInt8] {
        let dib = dib(side: n)

        var cur: [UInt8] = []
        appendU16(&cur, 0)               // reserved
        appendU16(&cur, 2)               // type: cursor
        appendU16(&cur, 1)               // count
        cur += [UInt8(n), UInt8(n), 0, 0]
        appendU16(&cur, hotspot.0); appendU16(&cur, hotspot.1)
        appendU32(&cur, dib.count)
        appendU32(&cur, 22)              // image offset (6 + 16)
        return cur + dib
    }

    /// The BMP image data of a cursor frame: header, BGRA pixels, AND mask.
    private static func dib(side n: Int) -> [UInt8] {
        var dib: [UInt8] = []
        appendU32(&dib, 40)              // biSize
        appendU32(&dib, n)               // biWidth
        appendU32(&dib, n * 2)           // biHeight (XOR bitmap + AND mask)
        appendU16(&dib, 1)               // biPlanes
        appendU16(&dib, 32)              // biBitCount
        appendU32(&dib, 0)               // biCompression BI_RGB
        appendU32(&dib, 0)               // biSizeImage
        appendU32(&dib, 0); appendU32(&dib, 0) // pixels-per-metre
        appendU32(&dib, 0); appendU32(&dib, 0) // palette counts
        for _ in 0..<(n * n) { dib += [40, 40, 220, 255] } // BGRA, opaque
        let maskRowBytes = ((n + 31) / 32) * 4
        dib += [UInt8](repeating: 0, count: maskRowBytes * n) // AND mask: fully opaque
        return dib
    }

    /// A RIFF ACON animation wrapping `rates.count` (or 3) copies of a `.cur` frame.
    static func ani(side n: Int, hotspot: (Int, Int), ratesInJiffies rates: [Int]?, defaultJiffies: Int = 10) -> [UInt8] {
        let frameCount = rates?.count ?? 3
        let frame = cur(side: n, hotspot: hotspot)

        var anih: [UInt8] = []
        appendU32(&anih, 36)             // cbSize
        appendU32(&anih, frameCount)     // nFrames
        appendU32(&anih, frameCount)     // nSteps
        appendU32(&anih, 0); appendU32(&anih, 0); appendU32(&anih, 0); appendU32(&anih, 0) // w,h,bpp,planes
        appendU32(&anih, defaultJiffies) // iDispRate
        appendU32(&anih, 1)              // bfAttributes: AF_ICON

        var fram: [UInt8] = fourCC("fram")
        for _ in 0..<frameCount { fram += chunk("icon", frame) }

        var body: [UInt8] = fourCC("ACON")
        body += chunk("anih", anih)
        if let rates { body += chunk("rate", rates.flatMap { u32($0) }) }
        body += chunk("LIST", fram)
        return chunk("RIFF", body)
    }

    private static func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        var out = fourCC(id)
        appendU32(&out, payload.count)
        out += payload
        if payload.count % 2 == 1 { out.append(0) } // RIFF word alignment
        return out
    }

    private static func fourCC(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
    private static func appendU32(_ a: inout [UInt8], _ v: Int) { a += u32(v) }
    private static func appendU16(_ a: inout [UInt8], _ v: Int) { a += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
}
