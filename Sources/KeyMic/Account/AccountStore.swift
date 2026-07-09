import Foundation
import Observation
import os

@Observable
final class AccountStore {
    static let shared = AccountStore(
        keychain: KeychainStore(),
        fetcher: { token in try await MeAPI.fetch(token: token) },
        now: { Date() }
    )

    private let keychain: KeychainStore
    private var fetcher: (String) async throws -> MeResponse
    private let now: () -> Date
    private let log = Logger(subsystem: "io.keymic.app", category: "account")

    private static let cacheTTL: TimeInterval = 5 * 60

    private(set) var user: MeResponse.User?
    private(set) var lastRevokedAt: Date?

    private var lastRefreshAt: Date?

    var signedIn: Bool { keychain.read() != nil && user != nil }

    init(keychain: KeychainStore,
         fetcher: @escaping (String) async throws -> MeResponse,
         now: @escaping () -> Date) {
        self.keychain = keychain
        self.fetcher = fetcher
        self.now = now
    }

    func injectFetcher(_ f: @escaping (String) async throws -> MeResponse) {
        self.fetcher = f
    }

    func refresh(force: Bool = false) async {
        guard let token = keychain.read() else {
            await MainActor.run { user = nil }
            return
        }
        let cached = await MainActor.run { () -> Bool in
            if !force, let last = lastRefreshAt, now().timeIntervalSince(last) < Self.cacheTTL {
                return true
            }
            lastRefreshAt = now()
            return false
        }
        if cached { return }
        do {
            let r = try await fetcher(token)
            await MainActor.run { user = r.user }
        } catch MeAPIError.unauthorized {
            log.warning("/me 401 — clearing keychain")
            keychain.delete()
            await MainActor.run {
                user = nil
                lastRevokedAt = now()
            }
        } catch {
            log.info("/me transient error: \(String(describing: error))")
        }
    }

    @MainActor
    func onLogin(token: String, user: MeResponse.User) {
        let saveStatus = keychain.save(token)
        self.user = user
        self.lastRefreshAt = now()
        self.lastRevokedAt = nil
        let isMain = Thread.isMainThread
        log.info("onLogin set user.email=\(user.email, privacy: .public) saveStatus=\(saveStatus) isMainThread=\(isMain) tokenLen=\(token.count)")
    }

    @MainActor
    func signOut() {
        keychain.delete()
        user = nil
        lastRevokedAt = nil
    }
}
