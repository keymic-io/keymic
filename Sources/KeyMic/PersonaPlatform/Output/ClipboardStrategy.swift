import Foundation

final class ClipboardStrategy: OutputStrategyHandler {
    private let write: @MainActor (String) -> Void

    /// Injected closure so production wiring (AppDelegate) can plumb the real
    /// pasteboard + `ClipboardController.markPasteboardWrite`, while tests pass
    /// a spy. Avoids dragging AppKit/SwiftData into the standalone test runner.
    init(write: @escaping @MainActor (String) -> Void) {
        self.write = write
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        await MainActor.run { self.write(text) }
    }
}
