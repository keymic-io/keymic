import Foundation
import Observation
import os

/// Per-section display status shown in the Account tab.
enum SectionSyncStatus: Equatable {
    case excluded          // section unchecked
    case notSynced         // never uploaded/downloaded
    case inSync            // local == cloud
    case localNewer        // local edits not yet uploaded
    case cloudNewer(Date)  // cloud has a newer version
}

/// State + actions backing the Account tab's Config Sync UI. Owns the sync
/// engine and the enabled-section / master-toggle preferences.
@MainActor
@Observable
final class ConfigSyncController {
    static let shared = ConfigSyncController()

    private let env: SyncEnvironment
    private let state: SyncStateStore
    private let engine: SyncEngine
    private let account: AccountStore
    private let tokenProvider: () -> String?
    private let log = Logger(subsystem: "io.keymic.app", category: "sync-ui")

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: SyncStateStore.masterEnabledKey) }
    }
    private(set) var enabledSections: Set<SyncSection>
    private(set) var statuses: [SyncSection: SectionSyncStatus] = [:]
    private(set) var busy = false
    private(set) var lastError: String?
    /// Set when the last download changed a section that needs an app restart.
    private(set) var restartHint = false
    /// True while the first-enable bootstrap needs the user to choose which side wins.
    var showBootstrapSheet = false

    /// AccountStore doesn't surface subscription plan yet, so Pro-gated UI stays
    /// disabled until that plumbing lands (P4). Auto-sync toggle reads this.
    var isPro = false

    init(env: SyncEnvironment = .live,
         state: SyncStateStore? = nil,
         account: AccountStore = .shared,
         deviceId: String? = AuthClient.hardwareUUID(),
         tokenProvider: @escaping () -> String? = { KeychainStore().read() }) {
        let st = state ?? SyncStateStore(defaults: .standard)
        self.env = env
        self.state = st
        self.account = account
        self.tokenProvider = tokenProvider
        self.engine = SyncEngine(env: env, state: st, deviceId: deviceId)
        self.enabled = UserDefaults.standard.bool(forKey: SyncStateStore.masterEnabledKey)
        self.enabledSections = Self.loadEnabledSections()
    }

    private static func loadEnabledSections() -> Set<SyncSection> {
        guard let raw = UserDefaults.standard.array(forKey: SyncStateStore.enabledSectionsKey) as? [String] else {
            // Default: everything except llm.
            return Set(SyncSection.allCases.filter { $0 != .llm })
        }
        return Set(raw.compactMap(SyncSection.init(rawValue:)))
    }

    private func persistEnabledSections() {
        UserDefaults.standard.set(enabledSections.map(\.rawValue), forKey: SyncStateStore.enabledSectionsKey)
    }

    func isSectionEnabled(_ s: SyncSection) -> Bool { enabledSections.contains(s) }

    func toggleSection(_ s: SyncSection, on: Bool) {
        if on { enabledSections.insert(s) } else { enabledSections.remove(s) }
        persistEnabledSections()
        statuses[s] = on ? (statuses[s] ?? .notSynced) : .excluded
    }

    // MARK: - First-enable bootstrap

    /// Called when the master toggle turns on. Decides whether to silently seed
    /// the cloud, silently adopt the cloud, prompt the user, or do nothing.
    func handleEnable() async {
        guard tokenProvider() != nil else { lastError = "Not signed in"; return }
        let cloudCount = await cloudSectionCount()
        let factory = localIsFactoryDefault()
        let differs = await localDiffersFromCloud()
        switch ConfigSyncBootstrap.decide(cloudSectionCount: cloudCount,
                                          localIsFactoryDefault: factory,
                                          localDiffersFromCloud: differs) {
        case .silentUpload: await uploadAll()
        case .silentDownload: await downloadAll()
        case .askUser: showBootstrapSheet = true
        case .noop: await refreshStatus()
        }
    }

    /// User picked "Use cloud settings" in the bootstrap sheet.
    func resolveBootstrapUseCloud() async { showBootstrapSheet = false; await downloadAll() }
    /// User picked "Keep this Mac's settings".
    func resolveBootstrapKeepLocal() async { showBootstrapSheet = false; await uploadAll() }
    /// User cancelled — revert the master toggle.
    func resolveBootstrapCancel() { showBootstrapSheet = false; enabled = false }

    /// True when no enabled section has any user-set local value (nothing to lose).
    func localIsFactoryDefault() -> Bool {
        for section in enabledSections {
            if section == .personas {
                if FileManager.default.fileExists(atPath: env.personasFileURL.path) { return false }
            } else if section.userDefaultsKeys.contains(where: { env.defaults.object(forKey: $0) != nil }) {
                return false
            }
        }
        return true
    }

    private func localDiffersFromCloud() async -> Bool {
        guard let token = tokenProvider(), let remote = try? await ConfigSyncAPI.get(token: token) else { return false }
        for section in enabledSections {
            let local = section.collectData(base: state.state(for: section).lastRemoteData ?? [:], env: env)
            if let r = remote.sections[section.rawValue], r.payload != local { return true }
        }
        return false
    }

    // MARK: - Actions

    func uploadAll() async { await run { try await self.engine.upload(sections: Array(self.enabledSections), token: $0) } }

    func downloadAll() async {
        await run { token in
            let changed = try await self.engine.download(applying: self.enabledSections, token: token)
            self.restartHint = changed.contains { !Self.hotReloadable.contains($0) }
            NotificationCenter.default.post(name: .configSyncDidApply, object: nil,
                                            userInfo: ["sections": changed.map(\.rawValue)])
        }
    }

    /// Sections whose apply takes effect immediately (reloaded live). Others need
    /// an app restart to be observed by components that read once at launch.
    static let hotReloadable: Set<SyncSection> = [.personas, .hotkeys, .keyMapping]

    private func run(_ body: @escaping (String) async throws -> Void) async {
        guard let token = tokenProvider() else { lastError = "Not signed in"; return }
        busy = true; lastError = nil
        defer { busy = false }
        do {
            try await body(token)
            await refreshStatus()
        } catch ConfigSyncError.unauthorized {
            await account.refresh(force: true) // will clear keychain on 401
            lastError = "Session expired — sign in again"
        } catch {
            lastError = "Sync failed"
            log.error("sync action failed: \(String(describing: error))")
        }
    }

    /// Fetch cloud state and recompute per-section display statuses.
    func refreshStatus() async {
        guard enabled, let token = tokenProvider() else { return }
        let remote: ConfigGetResponse
        do {
            remote = try await ConfigSyncAPI.get(token: token)
        } catch {
            log.info("status refresh failed: \(String(describing: error))")
            return
        }
        var next: [SyncSection: SectionSyncStatus] = [:]
        for section in SyncSection.allCases {
            guard enabledSections.contains(section) else { next[section] = .excluded; continue }
            let local = section.collectData(base: state.state(for: section).lastRemoteData ?? [:], env: env)
            if let r = remote.sections[section.rawValue] {
                if r.payload == local {
                    next[section] = .inSync
                } else {
                    let localMod = state.state(for: section).localModifiedAt ?? .distantPast
                    next[section] = localMod > r.modifiedAt ? .localNewer : .cloudNewer(r.modifiedAt)
                }
            } else {
                next[section] = .notSynced
            }
        }
        statuses = next
    }

    /// Cloud has at least one section AND local differs — used by the first-enable
    /// bootstrap (P3). Returns nil if no decision needed (safe to auto-sync).
    func cloudSectionCount() async -> Int {
        guard let token = tokenProvider(), let r = try? await ConfigSyncAPI.get(token: token) else { return 0 }
        return r.sections.count
    }
}

extension Notification.Name {
    static let configSyncDidApply = Notification.Name("io.keymic.app.configSyncDidApply")
}
