import Foundation
import os
import IOKit
#if canImport(AppKit)
import AppKit
#endif

enum AuthClient {
    private static let nonceKey = "io.keymic.app.auth.pendingNonce"
    private static let log = Logger(subsystem: "io.keymic.app", category: "auth-client")
    private static let nonceLock = NSLock()

    /// Hardware-stable UUID from IOPlatformExpertDevice. Survives reinstall; changes only on logic-board swap.
    static func hardwareUUID() -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (cf.takeRetainedValue() as? String)
    }

    // MARK: - Pure helpers (testable)

    static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            log.fault("SecRandomCopyBytes failed: \(status). Refusing to use predictable nonce.")
            fatalError("SecRandomCopyBytes failed (status=\(status)); cannot generate CSRF nonce")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func buildLoginURL(baseURL: URL, nonce: String) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("login"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "desktop", value: "1"),
            URLQueryItem(name: "state", value: nonce),
        ]
        return comps.url!
    }

    static func parseCallback(_ url: URL) -> (code: String, state: String)? {
        guard url.scheme == "keymic", url.host == "callback" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        guard let c = code, !c.isEmpty, let s = state, !s.isEmpty else { return nil }
        return (c, s)
    }

    // MARK: - Side-effecting flow

    static func beginLogin() {
        let nonce = generateNonce()
        UserDefaults.standard.set(nonce, forKey: nonceKey)
        let url = buildLoginURL(baseURL: BackendConfig.baseURL, nonce: nonce)
        log.info("opening login URL")
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Atomically consume the stored nonce; returns it if present, nil otherwise.
    private static func consumeNonce() -> String? {
        nonceLock.lock()
        defer { nonceLock.unlock() }
        let stored = UserDefaults.standard.string(forKey: nonceKey)
        UserDefaults.standard.removeObject(forKey: nonceKey)
        return stored
    }

    static func handleCallback(_ url: URL) async {
        guard let (code, state) = parseCallback(url) else {
            log.warning("malformed callback URL")
            return
        }
        guard let expected = consumeNonce(), expected == state else {
            log.warning("state mismatch — possible CSRF or stale callback")
            return
        }
        let deviceName = Host.current().localizedName
        let deviceId = hardwareUUID()
        do {
            let resp = try await ExchangeAPI.exchange(code: code, state: state, deviceId: deviceId, deviceName: deviceName)
            await MainActor.run {
                AccountStore.shared.onLogin(token: resp.accessToken, user: resp.user)
            }
            log.info("sign-in successful")
        } catch {
            log.error("exchange failed: \(String(describing: error))")
        }
    }
}
