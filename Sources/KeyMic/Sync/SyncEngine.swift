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

    /// Smallest bump that makes a merged write strictly newer than the record it
    /// supersedes, so the server (which rejects `modifiedAt <= current`) accepts it.
    private static let mergeBump: TimeInterval = 0.001

    /// Upload the given sections. Merge needs the current cloud state, so this
    /// GETs first. Scalar sections push their collected payload and lose to a
    /// newer cloud value (unchanged LWW). Collection sections push a
    /// base/local/remote item-merge; the merged union supersedes the cloud, so
    /// its PUT timestamp is bumped past the cloud record while the *real*
    /// localModifiedAt still decides item-level conflicts. On accept, the merged
    /// result is applied locally so remote-only additions are pulled in. A stale
    /// collection is re-merged against the returned newer record and re-PUT, up
    /// to two retries; still-stale (or any stale scalar) adopts cloud bookkeeping.
    @discardableResult
    func upload(sections: [SyncSection], token: String) async throws -> ConfigPutResponse {
        var remoteById = (try await transport.get(token: token)).sections
        var pending = sections
        var accepted: [String] = []
        var staleOut: [String: RemoteSection] = [:]
        var attempt = 0
        let maxAttempts = 3   // one initial PUT + two stale retries

        while !pending.isEmpty && attempt < maxAttempts {
            attempt += 1
            var entries: [String: ConfigPutEntry] = [:]
            var mergedByName: [String: [String: JSONValue]] = [:]
            for section in pending {
                let base = state.state(for: section).lastRemoteData ?? [:]
                let local = section.collectData(base: base, env: env)
                let conflictTime = state.state(for: section).localModifiedAt ?? now()
                let remote = remoteById[section.rawValue]
                let payload: [String: JSONValue]
                let putTime: Date
                switch section.mergePolicy {
                case .replace:
                    payload = local
                    putTime = conflictTime   // real LWW; a newer cloud value wins → stale → adopt
                case .mergeCollection:
                    let localNewer = conflictTime > (remote?.modifiedAt ?? .distantPast)
                    payload = section.mergedPayload(base: base, local: local,
                                                    remote: remote?.payload ?? [:], localNewer: localNewer)
                    if let rm = remote?.modifiedAt {
                        putTime = max(conflictTime, rm.addingTimeInterval(Self.mergeBump))
                    } else {
                        putTime = conflictTime
                    }
                    mergedByName[section.rawValue] = payload
                }
                entries[section.rawValue] = ConfigPutEntry(payload: payload, modifiedAt: putTime)
            }

            let resp = try await transport.put(ConfigPutBody(deviceId: deviceId, sections: entries), token: token)

            for name in resp.accepted {
                guard let section = SyncSection(rawValue: name), let entry = entries[name] else { continue }
                let prev = state.state(for: section).serverRevision ?? 0
                state.recordSynced(section, remoteData: entry.payload, revision: prev + 1, modifiedAt: entry.modifiedAt)
                if let merged = mergedByName[name] {
                    let wasApplying = state.isApplyingRemote
                    state.isApplyingRemote = true
                    section.applyData(merged, env: env)   // bring remote-only additions into local
                    state.isApplyingRemote = wasApplying
                }
                accepted.append(name)
            }

            var next: [SyncSection] = []
            for (name, record) in resp.stale {
                guard let section = SyncSection(rawValue: name) else { continue }
                remoteById[name] = record   // newer cloud record for the next merge
                switch section.mergePolicy {
                case .mergeCollection:
                    next.append(section)    // re-merge (union preserved) and retry
                case .replace:
                    // Scalar can never win a stale race; adopt cloud now.
                    state.recordSynced(section, remoteData: record.payload, revision: record.revision, modifiedAt: record.modifiedAt)
                    staleOut[name] = record
                }
            }
            pending = next
        }

        // Collections still stale after the retry budget → adopt cloud bookkeeping.
        for section in pending {
            guard let record = remoteById[section.rawValue] else { continue }
            state.recordSynced(section, remoteData: record.payload, revision: record.revision, modifiedAt: record.modifiedAt)
            staleOut[section.rawValue] = record
        }
        return ConfigPutResponse(accepted: accepted, stale: staleOut)
    }

    /// Download all sections and apply the given enabled ones locally. Collection
    /// sections are item-merged against local; scalar sections adopt the cloud
    /// value (unchanged). No PUT — the base recorded is the cloud value. When a
    /// collection merge leaves local-only items (`merged != remote`), the
    /// section's `localModifiedAt` is stamped just past the cloud time so status
    /// reports `.localNewer` (prompting an Upload). Returns the sections whose
    /// local values actually changed.
    @discardableResult
    func download(applying enabled: Set<SyncSection>, token: String) async throws -> [SyncSection] {
        let resp = try await transport.get(token: token)
        var changed: [SyncSection] = []
        state.isApplyingRemote = true
        defer { state.isApplyingRemote = false }
        for (name, record) in resp.sections {
            guard let section = SyncSection(rawValue: name), enabled.contains(section) else { continue }
            let base = state.state(for: section).lastRemoteData ?? [:]
            let local = section.collectData(base: base, env: env)
            let applyValue: [String: JSONValue]
            let stampedAt: Date
            switch section.mergePolicy {
            case .replace:
                applyValue = record.payload            // pull adopts cloud
                stampedAt = record.modifiedAt
            case .mergeCollection:
                let localMod = state.state(for: section).localModifiedAt ?? .distantPast
                let localNewer = localMod > record.modifiedAt
                applyValue = section.mergedPayload(base: base, local: local,
                                                   remote: record.payload, localNewer: localNewer)
                stampedAt = applyValue == record.payload
                    ? record.modifiedAt
                    : max(localMod, record.modifiedAt.addingTimeInterval(Self.mergeBump))
            }
            if local != applyValue {
                section.applyData(applyValue, env: env)
                changed.append(section)
            }
            // Cloud holds `record.payload` (we did not push); record it as the base.
            state.recordSynced(section, remoteData: record.payload, revision: record.revision, modifiedAt: stampedAt)
        }
        return changed
    }
}
