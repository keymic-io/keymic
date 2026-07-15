import Foundation

// Standalone runner (swiftc @main). Covers SyncStateStore bookkeeping and
// SyncEngine upload/download against a fake ConfigTransport.

final class FakeTransport: ConfigTransport, @unchecked Sendable {
    var getResponse: ConfigGetResponse = ConfigGetResponse(sections: [:])
    var putResponse: ConfigPutResponse = ConfigPutResponse(accepted: [], stale: [:])
    var getError: Error?
    var putError: Error?
    var lastPutBody: ConfigPutBody?

    func get(token: String) async throws -> ConfigGetResponse {
        if let getError { throw getError }
        return getResponse
    }
    func put(_ body: ConfigPutBody, token: String) async throws -> ConfigPutResponse {
        lastPutBody = body
        if let putError { throw putError }
        return putResponse
    }
}

@main
struct SyncEngineTests {
    static func expect(_ cond: Bool, _ msg: String) { if !cond { fatalError("FAILED: \(msg)") } }

    static func newState() -> SyncStateStore {
        let suite = "io.keymic.app.tests.syncstate.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return SyncStateStore(defaults: d, now: { Date(timeIntervalSince1970: 1_000_000) })
    }

    static func makeEnv() -> SyncEnvironment {
        let suite = "io.keymic.app.tests.syncenv.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return SyncEnvironment(defaults: d, personasFileURL: tmp)
    }

    static func main() async {
        testDirtyGatedByApplying()
        testKeyRouting()
        testBootstrapDecision()
        await testUploadAccepted()
        await testUploadStaleAdopts()
        await testUploadStampsTrackedModifiedAt()
        await testDownloadAppliesChanged()
        await testDownloadSkipsUnchanged()
        await testUnauthorizedPropagates()
        print("SyncEngineTests passed")
    }

    static func testDirtyGatedByApplying() {
        let s = newState()
        s.markDirty(.voice)
        expect(s.state(for: .voice).localModifiedAt != nil, "markDirty sets modifiedAt")
        let s2 = newState()
        s2.isApplyingRemote = true
        s2.markDirty(.voice)
        expect(s2.state(for: .voice).localModifiedAt == nil, "no dirty while applying remote")
    }

    static func testKeyRouting() {
        expect(SyncStateStore.section(forDefaultsKey: "voiceEnabled") == .voice, "voiceEnabled → voice")
        expect(SyncStateStore.section(forDefaultsKey: "keyMappingList") == .keyMapping, "keyMappingList → keyMapping")
        expect(SyncStateStore.section(forDefaultsKey: "llmAPIKey") == nil, "llmAPIKey is not owned by any section")
        expect(SyncStateStore.section(forDefaultsKey: "unrelated") == nil, "unknown key routes nowhere")
    }

    static func testBootstrapDecision() {
        typealias B = ConfigSyncBootstrap
        expect(B.decide(cloudSectionCount: 0, localIsFactoryDefault: false, localDiffersFromCloud: true) == .silentUpload,
               "empty cloud → silent upload")
        expect(B.decide(cloudSectionCount: 0, localIsFactoryDefault: true, localDiffersFromCloud: false) == .silentUpload,
               "empty cloud wins even if local is default")
        expect(B.decide(cloudSectionCount: 3, localIsFactoryDefault: true, localDiffersFromCloud: true) == .silentDownload,
               "factory-default local → silent download")
        expect(B.decide(cloudSectionCount: 3, localIsFactoryDefault: false, localDiffersFromCloud: true) == .askUser,
               "both sides differ → ask user")
        expect(B.decide(cloudSectionCount: 3, localIsFactoryDefault: false, localDiffersFromCloud: false) == .noop,
               "already in sync → noop")
    }

    static func testUploadAccepted() async {
        let env = makeEnv()
        env.defaults.set(true, forKey: "voiceEnabled")
        let state = newState()
        let t = FakeTransport()
        t.putResponse = ConfigPutResponse(accepted: ["voice"], stale: [:])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let resp = try! await engine.upload(sections: [.voice], token: "tok")
        expect(resp.accepted == ["voice"], "voice accepted")
        expect(state.state(for: .voice).serverRevision == 1, "revision bumped to 1")
        expect(state.state(for: .voice).lastRemoteData?["voiceEnabled"] == .bool(true), "remote data cached")
        expect(t.lastPutBody?.deviceId == "devA", "deviceId forwarded")
        expect(t.lastPutBody?.sections["voice"]?.payload["voiceEnabled"] == .bool(true), "collected payload uploaded")
    }

    static func testUploadStaleAdopts() async {
        let env = makeEnv()
        env.defaults.set(true, forKey: "voiceEnabled")
        let state = newState()
        let t = FakeTransport()
        t.putResponse = ConfigPutResponse(accepted: [], stale: [
            "voice": RemoteSection(payload: ["voiceEnabled": .bool(false)],
                                    modifiedAt: Date(timeIntervalSince1970: 2_000_000),
                                    revision: 7, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let resp = try! await engine.upload(sections: [.voice], token: "tok")
        expect(resp.accepted.isEmpty, "nothing accepted")
        expect(state.state(for: .voice).serverRevision == 7, "adopted server revision 7")
        expect(state.state(for: .voice).lastRemoteData?["voiceEnabled"] == .bool(false), "adopted server payload")
    }

    static func testUploadStampsTrackedModifiedAt() async {
        let env = makeEnv()
        env.defaults.set(true, forKey: "voiceEnabled")
        let state = newState()
        let stamp = Date(timeIntervalSince1970: 1_500_000)
        state.recordSynced(.voice, remoteData: [:], revision: 2, modifiedAt: stamp)
        let t = FakeTransport()
        t.putResponse = ConfigPutResponse(accepted: ["voice"], stale: [:])
        let engine = SyncEngine(env: env, state: state, deviceId: nil, transport: t)
        _ = try! await engine.upload(sections: [.voice], token: "tok")
        expect(t.lastPutBody?.sections["voice"]?.modifiedAt == stamp, "uploads tracked localModifiedAt")
    }

    static func testDownloadAppliesChanged() async {
        let env = makeEnv()
        let state = newState()
        let t = FakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "voice": RemoteSection(payload: ["voiceEnabled": .bool(true), "selectedLocaleCode": .string("fr-FR")],
                                   modifiedAt: Date(timeIntervalSince1970: 2_000_000),
                                   revision: 3, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let changed = try! await engine.download(applying: [.voice], token: "tok")
        expect(changed.contains(.voice), "voice reported changed")
        expect(env.defaults.string(forKey: "selectedLocaleCode") == "fr-FR", "locale applied from remote")
        expect(state.state(for: .voice).serverRevision == 3, "revision recorded")
    }

    static func testDownloadSkipsUnchanged() async {
        let env = makeEnv()
        env.defaults.set(true, forKey: "voiceEnabled")
        let state = newState()
        let t = FakeTransport()
        // Remote payload equals what we'd collect locally → no change, not reported.
        t.getResponse = ConfigGetResponse(sections: [
            "voice": RemoteSection(payload: ["voiceEnabled": .bool(true)],
                                   modifiedAt: Date(timeIntervalSince1970: 2_000_000),
                                   revision: 5, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let changed = try! await engine.download(applying: [.voice], token: "tok")
        expect(!changed.contains(.voice), "unchanged section not reported")
        expect(state.state(for: .voice).serverRevision == 5, "revision still recorded on unchanged")
    }

    static func testUnauthorizedPropagates() async {
        let env = makeEnv()
        let t = FakeTransport()
        t.getError = ConfigSyncError.unauthorized
        let engine = SyncEngine(env: env, state: newState(), deviceId: nil, transport: t)
        do {
            _ = try await engine.download(applying: [.voice], token: "tok")
            fatalError("FAILED: expected unauthorized to throw")
        } catch ConfigSyncError.unauthorized {
            // expected
        } catch {
            fatalError("FAILED: expected .unauthorized, got \(error)")
        }
    }
}
