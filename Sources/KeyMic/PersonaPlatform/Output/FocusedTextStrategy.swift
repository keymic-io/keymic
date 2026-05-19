import Foundation
import AppKit

// Temporary location — moves into OutputRouter.swift in Task 11.
protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool

    static let defaults = StrategyOptions(reactivateOrigin: true)
}

final class FocusedTextStrategy: OutputStrategyHandler {
    private let inject: (String) -> Void
    private let reactivate: (String) -> Void

    init(textInjector: TextInjector,
         reactivate: @escaping (String) -> Void = { bundleID in
             if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                 app.activate(options: [])
             }
         }) {
        self.inject = { text in textInjector.inject(text) }
        self.reactivate = reactivate
    }

    /// Test-only init that takes a custom inject closure.
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
