import Foundation

final class FocusedTextStrategy: OutputStrategyHandler {
    private let inject: (String) -> Void
    private let reactivate: (String) -> Void

    /// Injected closures so production wiring (AppDelegate) can plumb `TextInjector`
    /// + `NSRunningApplication`, while tests pass spies. Avoids dragging AppKit
    /// types into the standalone test runner.
    init(inject: @escaping (String) -> Void,
         reactivate: @escaping (String) -> Void) {
        self.inject = inject
        self.reactivate = reactivate
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        if options.reactivateOrigin, let bid = origin {
            await MainActor.run { self.reactivate(bid) }
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms (matches existing injectAfterPop)
        await MainActor.run { self.inject(text) }
    }
}
