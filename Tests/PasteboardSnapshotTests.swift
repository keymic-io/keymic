import AppKit
import Foundation

@main
struct PasteboardSnapshotTestRunner {
    static func main() {
        testPlainTextRoundTrip()
        testEmptyPasteboard()
        testImageRoundTrip()
        testRichTextRoundTrip()
        testTokenPriority()
        print("PasteboardSnapshotTests passed")
    }

    /// Plain text: snapshot captures string, restore reproduces it, ignoredToken matches.
    static func testPlainTextRoundTrip() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("hello world", forType: .string)

        let snap = PasteboardSnapshot.capture(pb)
        expect(snap.plainText == "hello world", "captured plain text")
        expect(snap.imageHashHex == nil, "no image hash")
        expect(snap.filePath == nil, "no file path")
        expect(snap.ignoredToken == "hello world", "token is plain text")

        pb.clearContents()
        pb.setString("scratch", forType: .string)
        PasteboardSnapshot.restore(snap, to: pb)
        expect(pb.string(forType: .string) == "hello world", "plain text restored")
    }

    /// Empty pasteboard: snapshot has no items, restore is a no-op past clearContents.
    static func testEmptyPasteboard() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()

        let snap = PasteboardSnapshot.capture(pb)
        expect(snap.items.isEmpty, "no items captured")
        expect(snap.ignoredToken == nil, "no token for empty pasteboard")

        pb.setString("scratch", forType: .string)
        PasteboardSnapshot.restore(snap, to: pb)
        expect(pb.string(forType: .string) == nil, "restored to empty")
    }

    /// PNG bytes round-trip; ignoredToken is sha256 hex (64 chars).
    static func testImageRoundTrip() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()

        // Minimal valid 1x1 PNG.
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
        let pngType = NSPasteboard.PasteboardType("public.png")
        let item = NSPasteboardItem()
        item.setData(png, forType: pngType)
        pb.writeObjects([item])

        let snap = PasteboardSnapshot.capture(pb)
        expect(snap.imageHashHex != nil, "image hash captured")
        expect(snap.imageHashHex?.count == 64, "sha256 hex is 64 chars")
        expect(snap.ignoredToken == snap.imageHashHex, "token prefers image hash")

        pb.clearContents()
        PasteboardSnapshot.restore(snap, to: pb)
        let restored = pb.data(forType: pngType)
        expect(restored == png, "PNG bytes round-trip")
    }

    /// HTML rich text: ignoredToken falls back to plain text (matches ClipboardMonitor branch).
    static func testRichTextRoundTrip() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let html = "<b>hi</b>"
        let plain = "hi"
        let item = NSPasteboardItem()
        item.setData(html.data(using: .utf8)!, forType: NSPasteboard.PasteboardType("public.html"))
        item.setString(plain, forType: .string)
        pb.writeObjects([item])

        let snap = PasteboardSnapshot.capture(pb)
        expect(snap.imageHashHex == nil, "no image hash for HTML")
        expect(snap.filePath == nil, "no file path for HTML")
        expect(snap.ignoredToken == plain, "token is plain-text fallback")

        pb.clearContents()
        PasteboardSnapshot.restore(snap, to: pb)
        expect(
            pb.data(forType: NSPasteboard.PasteboardType("public.html")) == html.data(using: .utf8),
            "HTML restored"
        )
        expect(pb.string(forType: .string) == plain, "plain text restored alongside HTML")
    }

    /// When image+text coexist on the pasteboard, ignoredToken prefers image hash —
    /// matches the order in ClipboardMonitor.tick() (image branch before plain text).
    static func testTokenPriority() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
        let item = NSPasteboardItem()
        item.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
        item.setString("description", forType: .string)
        pb.writeObjects([item])

        let snap = PasteboardSnapshot.capture(pb)
        expect(snap.imageHashHex != nil, "image hash present")
        expect(snap.plainText == "description", "plain text also captured")
        expect(snap.ignoredToken == snap.imageHashHex, "token prefers image over text")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
