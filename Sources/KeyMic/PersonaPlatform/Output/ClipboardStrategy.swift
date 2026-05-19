import AppKit
import Foundation

final class ClipboardStrategy: OutputStrategyHandler {
    private let write: @MainActor (String) -> Void

    init(controller: ClipboardController) {
        self.write = { @MainActor [weak controller] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            controller?.markPasteboardWrite(text)
        }
    }

    /// Test-only init.
    init(write: @escaping @MainActor (String) -> Void) {
        self.write = write
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        await MainActor.run { self.write(text) }
    }
}
