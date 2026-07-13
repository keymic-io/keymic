import Foundation
import Observation
import os

/// Aggregate sync status shown as a single line in the Account tab.
enum OverallSyncStatus: Equatable {
    case notSynced   // nothing uploaded/downloaded yet
    case inSync      // local == cloud across all sections
    case localNewer  // local edits not yet uploaded
    case cloudNewer  // cloud has newer changes to pull
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

    /// Last locally-observed payload per section. Lets `noteLocalChange` tell a
    /// genuine new edit (bump the LWW timestamp) from an unrelated defaults write
    /// (leave it alone), independent of the remote baseline.
    private var lastSeenLocal: [SyncSection: [String: JSONValue]] = [:]

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: SyncStateStore.masterEnabledKey) }
    }
    /// Sync is whole-config: every section syncs. The LLM API key is never
    /// carried — `SyncSection.llm.userDefaultsKeys` deliberately omits it.
    let enabledSections = Set(SyncSection.allCases)
    private(set) var overall: OverallSyncStatus = .notSynced
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
        NotificationCenter.default.addObserver(
            forName: AccountStore.didSignOutNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSignOut() }
        }
    }

    /// Sign-out invalidates everything account-scoped: per-section revision/remote
    /// caches (a different account must never inherit this account's
    /// `lastRemoteData` as its upload base), the local-edit tracker, and the
    /// master toggle (re-enabling after the next sign-in re-runs the
    /// first-enable bootstrap against that account's cloud).
    func handleSignOut() {
        enabled = false
        state.reset()
        lastSeenLocal.removeAll()
        overall = .notSynced
        lastError = nil
        restartHint = false
    }

    /// Timestamp of the most recently synced section, for the "last synced" line.
    /// Derived from state so it survives restarts (no separate storage).
    var lastSyncedAt: Date? {
        enabledSections
            .compactMap { s in state.state(for: s).serverRevision != nil ? state.state(for: s).localModifiedAt : nil }
            .max()
    }

    /// Called when local configuration might have changed (a UserDefaults write or
    /// a personas-file save). Bumps the LWW `localModifiedAt` of any enabled
    /// section whose collected payload actually changed, so `refreshStatus` reports
    /// `.localNewer` and `upload` stamps a current timestamp instead of a stale one.
    ///
    /// Two guards keep this honest:
    /// - `!= remote`: a payload equal to the last-synced value is a remote-apply
    ///   echo (`recordSynced` already updated `lastRemoteData`), never a local edit.
    /// - `!= seen`: an unrelated defaults write must not re-stamp a section that
    ///   didn't change, or churn would push every dirty section's timestamp forward
    ///   and clobber a newer copy from another device.
    func noteLocalChange() {
        guard enabled, !state.isApplyingRemote else { return }
        for section in enabledSections {
            let remote = state.state(for: section).lastRemoteData ?? [:]
            let current = section.collectData(base: remote, env: env)
            let seen = lastSeenLocal[section] ?? remote
            lastSeenLocal[section] = current
            if current != remote && current != seen {
                state.markDirty(section)
            }
        }
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

    func uploadAll() async {
        await run { token in
            let resp = try await self.engine.upload(sections: Array(self.enabledSections), token: token)
            // Accepted collection sections were merged and applied to local storage;
            // hot-reload their in-memory stores (upload posts no download notification).
            let reload = resp.accepted.compactMap(SyncSection.init(rawValue:)).filter(Self.hotReloadable.contains)
            if !reload.isEmpty {
                NotificationCenter.default.post(name: .configSyncDidApply, object: nil,
                                                userInfo: ["sections": reload.map(\.rawValue)])
            }
        }
    }

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

    /// Fetch cloud state and recompute the aggregate display status.
    func refreshStatus() async {
        guard enabled, let token = tokenProvider() else { return }
        let remote: ConfigGetResponse
        do {
            remote = try await ConfigSyncAPI.get(token: token)
        } catch {
            log.info("status refresh failed: \(String(describing: error))")
            return
        }
        var anyLocalNewer = false, anyCloudNewer = false, anyInSync = false
        for section in enabledSections {
            let local = section.collectData(base: state.state(for: section).lastRemoteData ?? [:], env: env)
            if let r = remote.sections[section.rawValue] {
                if r.payload == local {
                    anyInSync = true
                } else {
                    let localMod = state.state(for: section).localModifiedAt ?? .distantPast
                    if localMod > r.modifiedAt { anyLocalNewer = true } else { anyCloudNewer = true }
                }
            } else if !local.isEmpty {
                // Never uploaded but has local content — waiting to push.
                anyLocalNewer = true
            }
        }
        overall = anyLocalNewer ? .localNewer
            : anyCloudNewer ? .cloudNewer
            : anyInSync ? .inSync
            : .notSynced
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
