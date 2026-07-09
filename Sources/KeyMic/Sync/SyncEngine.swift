import Foundation
import os

/// Coordinates collect/apply (`SyncSection`), local bookkeeping (`SyncStateStore`),
/// and the backend (`ConfigSyncAPI`). Pure of UI; callers pass the token and the
/// set of enabled sections.
final class SyncEngine {
    private let env: SyncEnvironment
    private let state: SyncStateStore
    private let deviceId: String?
    private let transport: ConfigTransport
    private let now: () -> Date
    private let log = Logger(subsystem: "io.keymic.app", category: "sync")

    init(env: SyncEnvironment = .live,
         state: SyncStateStore,
         deviceId: String?,
         transport: ConfigTransport = LiveConfigTransport(),
         now: @escaping () -> Date = { Date() }) {
        self.env = env
        self.state = state
        self.deviceId = deviceId
        self.transport = transport
        self.now = now
    }

    /// Upload the given sections. Each section's payload is collected over its
    /// last-seen remote data (unknown-field preservation) and stamped with its
    /// tracked localModifiedAt (falling back to now). Accepted sections update
    /// bookkeeping; stale sections are downloaded into local bookkeeping so the
    /// next reconcile sees the server value.
    @discardableResult
    func upload(sections: [SyncSection], token: String) async throws -> ConfigPutResponse {
        var entries: [String: ConfigPutEntry] = [:]
        for section in sections {
            let base = state.state(for: section).lastRemoteData ?? [:]
            let data = section.collectData(base: base, env: env)
            let modifiedAt = state.state(for: section).localModifiedAt ?? now()
            entries[section.rawValue] = ConfigPutEntry(payload: data, modifiedAt: modifiedAt)
        }
        let body = ConfigPutBody(deviceId: deviceId, sections: entries)
        let resp = try await transport.put(body, token: token)

        for name in resp.accepted {
            guard let section = SyncSection(rawValue: name),
                  let entry = entries[name] else { continue }
            // Server revision for an accepted write = previous + 1; we may not know
            // the exact number, so re-fetch is authoritative. For now bump locally.
            let prev = state.state(for: section).serverRevision ?? 0
            state.recordSynced(section, remoteData: entry.payload, revision: prev + 1, modifiedAt: entry.modifiedAt)
        }
        for (name, record) in resp.stale {
            guard let section = SyncSection(rawValue: name) else { continue }
            // The server has a newer value than ours; adopt its bookkeeping so a
            // subsequent download/reconcile applies it rather than re-uploading.
            state.recordSynced(section, remoteData: record.payload, revision: record.revision, modifiedAt: record.modifiedAt)
        }
        return resp
    }

    /// Download all sections and apply the given enabled ones locally. Returns the
    /// section keys whose local values actually changed.
    @discardableResult
    func download(applying enabled: Set<SyncSection>, token: String) async throws -> [SyncSection] {
        let resp = try await transport.get(token: token)
        var changed: [SyncSection] = []
        state.isApplyingRemote = true
        defer { state.isApplyingRemote = false }
        for (name, record) in resp.sections {
            guard let section = SyncSection(rawValue: name), enabled.contains(section) else { continue }
            let before = section.collectData(base: state.state(for: section).lastRemoteData ?? [:], env: env)
            if before != record.payload {
                section.applyData(record.payload, env: env)
                changed.append(section)
            }
            state.recordSynced(section, remoteData: record.payload, revision: record.revision, modifiedAt: record.modifiedAt)
        }
        return changed
    }
}
