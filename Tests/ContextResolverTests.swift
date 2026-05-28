import Foundation

@main
struct ContextResolverTestRunner {
    static func main() {
        run()
        print("ContextResolverTests passed")
    }

    static func run() {
        testNoSourcesProducesEmptyContext()
        testSelectionOnly()
        testClipboardTopOnly()
        testClipboardHistoryOnly()
        testSelectionAndClipboard()
        testWindowOCRStubReturnsNil()
        testOCRStatusUpdate()
        testOCRErrorSwallowed()
    }

    // MARK: - Tests against PersonaContextBuilder.gather

    static func testNoSourcesProducesEmptyContext() {
        let providers = makeProviders(selection: "SEL", clipboardTop: "CLIP", history: ["H0", "H1"], ocr: "OCR")
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.selection == nil, "empty sources → nil selection")
        expect(ctx.clipboardTop == nil, "empty sources → nil clipboard")
        expect(ctx.clipboardHistory == nil, "empty sources → nil history")
        expect(ctx.windowOCR == nil, "empty sources → nil OCR")
    }

    static func testSelectionOnly() {
        let providers = makeProviders(selection: "SEL", clipboardTop: nil, history: [], ocr: nil)
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.selection], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.selection == "SEL", "selection source → selection captured")
        expect(ctx.clipboardTop == nil, "selection-only → no clipboard")
        expect(ctx.clipboardHistory == nil, "selection-only → no history")
    }

    static func testClipboardTopOnly() {
        let providers = makeProviders(selection: nil, clipboardTop: "CLIP", history: [], ocr: nil)
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.clipboardTop], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.clipboardTop == "CLIP", "clipboardTop source → clipboard captured")
        expect(ctx.selection == nil, "clipboard-only → no selection")
    }

    static func testClipboardHistoryOnly() {
        let providers = makeProviders(selection: nil, clipboardTop: nil, history: ["a", "b"], ocr: nil)
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.clipboardHistory], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.clipboardHistory?.count == 2, "clipboardHistory → 2 items, got \(ctx.clipboardHistory?.count ?? 0)")
        expect(ctx.clipboardHistory?[0] == "a", "clipboardHistory[0] == a")
    }

    static func testSelectionAndClipboard() {
        let providers = makeProviders(selection: "S", clipboardTop: "C", history: [], ocr: nil)
        let sources: Set<ContextSource> = [.selection, .clipboardTop]
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: sources, providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.selection == "S", "both → selection captured")
        expect(ctx.clipboardTop == "C", "both → clipboard captured")
    }

    static func testWindowOCRStubReturnsNil() {
        let providers = makeProviders(selection: nil, clipboardTop: nil, history: [], ocr: nil)
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.windowOCR], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.windowOCR == nil, "nil OCR stub → nil OCR")
    }

    static func testOCRStatusUpdate() {
        let providers = makeProviders(selection: nil, clipboardTop: nil, history: [], ocr: "screen text")
        var statuses: [String] = []
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.windowOCR], providers: providers) { s in
                statuses.append(s)
            }
        }
        expect(statuses.contains { $0.contains("Reading screen") }, "OCR should trigger status update")
        expect(ctx.windowOCR == "screen text", "OCR text captured")
    }

    static func testOCRErrorSwallowed() {
        let providers = PersonaContextBuilder.Providers(
            selection: { nil },
            clipboardTop: { nil },
            clipboardHistory: { _ in nil },
            windowOCR: { throw NSError(domain: "ocr", code: 1) }
        )
        let ctx = sync {
            await PersonaContextBuilder.gather(sources: [.windowOCR], providers: providers, onStatusUpdate: { _ in })
        }
        expect(ctx.windowOCR == nil, "OCR error → silently nil")
    }

    // MARK: - helpers

    static func makeProviders(selection: String?, clipboardTop: String?, history: [String], ocr: String?) -> PersonaContextBuilder.Providers {
        PersonaContextBuilder.Providers(
            selection: { selection },
            clipboardTop: { clipboardTop },
            clipboardHistory: { limit in Array(history.prefix(limit)) },
            windowOCR: {
                if let ocr { return ocr }
                return nil
            }
        )
    }

    static func sync<T>(_ work: @escaping () async -> T) -> T {
        var result: T?
        let sema = DispatchSemaphore(value: 0)
        Task { result = await work(); sema.signal() }
        sema.wait()
        return result!
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
