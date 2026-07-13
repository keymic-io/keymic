import Foundation

// Standalone runner (swiftc @main). Covers the pure item-merge core, section
// merge policy, and the merge-aware SyncEngine download/upload flows.

final class MergeFakeTransport: ConfigTransport, @unchecked Sendable {
    var getResponse = ConfigGetResponse(sections: [:])
    var putResponses: [ConfigPutResponse] = []          // dequeued per PUT call
    var putBodies: [ConfigPutBody] = []
    func get(token: String) async throws -> ConfigGetResponse { getResponse }
    func put(_ body: ConfigPutBody, token: String) async throws -> ConfigPutResponse {
        putBodies.append(body)
        return putResponses.isEmpty ? ConfigPutResponse(accepted: [], stale: [:]) : putResponses.removeFirst()
    }
}

@main
struct SyncMergeTests {
    static func expect(_ cond: Bool, _ msg: String) { if !cond { fatalError("FAILED: \(msg)") } }

    static func item(_ id: String, _ v: Int) -> JSONValue { .object(["id": .string(id), "v": .int(v)]) }
    static func ids(_ arr: [JSONValue]) -> [String] { arr.compactMap { itemId($0, idKey: "id") } }

    static func main() async {
        // Pure merge core.
        testAddOnlyUnion()
        testLocalDeletionPropagates()
        testRemoteOnlyAddPulledIn()
        testBothEditSectionLWW()
        testDeleteVsEdit()
        testEditVsDelete()
        testBothSidesDelete()
        testOrderStability()
        testDuplicateIdDedup()
        testNoIdItemDropped()
        // Path helpers.
        testPathExtractAndSplice()
        // Section policy.
        testSectionCollectionMergePreservesScalar()
        testSectionReplaceIsLWW()
        testSectionPersonasEnvelopePath()
        testSectionAbsentPathNotMaterialized()
        // Engine flows.
        await testDownloadMergesAndRecordsRemoteBase()
        await testDownloadStatusBecomesLocalNewer()
        await testUploadPutsMergedAndConverges()
        await testUploadKeyMappingRoundTrip()
        await testUploadStaleRetryDeliversLocalAdd()
        print("SyncMergeTests passed")
    }

    // MARK: - Pure merge core

    static func testAddOnlyUnion() {
        let out = mergeItemArrays(base: [], local: [item("a", 1)], remote: [item("b", 1)],
                                  idKey: "id", localNewer: true)
        expect(ids(out) == ["a", "b"], "add-only union keeps both (local first, remote appended)")
    }

    static func testLocalDeletionPropagates() {
        let out = mergeItemArrays(base: [item("a", 1)], local: [], remote: [item("a", 1)],
                                  idKey: "id", localNewer: true)
        expect(out.isEmpty, "local deletion of an unchanged item drops it")
    }

    static func testRemoteOnlyAddPulledIn() {
        let out = mergeItemArrays(base: [], local: [item("a", 1)], remote: [item("a", 1), item("b", 9)],
                                  idKey: "id", localNewer: false)
        expect(ids(out) == ["a", "b"], "remote-only add pulled in")
    }

    static func testBothEditSectionLWW() {
        let base = [item("a", 1)], local = [item("a", 2)], remote = [item("a", 3)]
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: true) == [item("a", 2)],
               "both-edit: localNewer keeps local")
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: false) == [item("a", 3)],
               "both-edit: !localNewer takes remote")
    }

    static func testDeleteVsEdit() {
        let base = [item("a", 1)], local = [item("a", 2)], remote: [JSONValue] = []
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: true) == [item("a", 2)],
               "delete-vs-edit: localNewer keeps local edit")
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: false).isEmpty,
               "delete-vs-edit: !localNewer honors remote deletion")
    }

    static func testEditVsDelete() {
        let base = [item("a", 1)], local: [JSONValue] = [], remote = [item("a", 5)]
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: true).isEmpty,
               "edit-vs-delete: localNewer honors local deletion")
        expect(mergeItemArrays(base: base, local: local, remote: remote, idKey: "id", localNewer: false) == [item("a", 5)],
               "edit-vs-delete: !localNewer takes remote edit")
    }

    static func testBothSidesDelete() {
        let out = mergeItemArrays(base: [item("a", 1)], local: [], remote: [], idKey: "id", localNewer: true)
        expect(out.isEmpty, "deleted on both sides → dropped")
    }

    static func testOrderStability() {
        let out = mergeItemArrays(base: [], local: [item("x", 1), item("y", 1)],
                                  remote: [item("z", 1), item("y", 1)], idKey: "id", localNewer: true)
        expect(ids(out) == ["x", "y", "z"], "local order first, remote-only appended in remote order")
    }

    static func testDuplicateIdDedup() {
        let out = mergeItemArrays(base: [], local: [item("a", 1), item("a", 2)], remote: [],
                                  idKey: "id", localNewer: true)
        expect(out == [item("a", 1)], "duplicate ids collapse to first occurrence")
    }

    static func testNoIdItemDropped() {
        let noId: JSONValue = .object(["v": .int(1)])
        let out = mergeItemArrays(base: [], local: [noId, item("a", 1)], remote: [], idKey: "id", localNewer: true)
        expect(out == [item("a", 1)], "items without a usable id are dropped")
    }

    // MARK: - Path helpers

    static func testPathExtractAndSplice() {
        let payload: [String: JSONValue] = [
            "hotkeyBindings": .object(["__json_data__": .array([item("a", 1)])]),
            "hotkeysEnabled": .bool(true),
        ]
        expect(jsonArray(at: ["hotkeyBindings", "__json_data__"], in: payload) == [item("a", 1)],
               "jsonArray reads nested array")
        expect(jsonArrayIfPresent(at: ["missing", "x"], in: payload) == nil, "missing path is nil, not empty")
        let spliced = settingJSONArray([item("a", 1), item("b", 2)],
                                       at: ["hotkeyBindings", "__json_data__"], in: payload)
        expect(jsonArray(at: ["hotkeyBindings", "__json_data__"], in: spliced) == [item("a", 1), item("b", 2)],
               "settingJSONArray replaces nested array")
        expect(spliced["hotkeysEnabled"] == .bool(true), "settingJSONArray preserves scalar siblings")
    }

    // MARK: - Section policy

    static func hotkeysPayload(_ enabled: Bool, _ items: [JSONValue]) -> [String: JSONValue] {
        ["hotkeysEnabled": .bool(enabled),
         "hotkeyBindings": .object(["__json_data__": .array(items)])]
    }

    static func testSectionCollectionMergePreservesScalar() {
        let base = hotkeysPayload(true, [item("a", 1)])
        let local = hotkeysPayload(false, [item("a", 1), item("b", 1)])   // local added b, toggled off
        let remote = hotkeysPayload(true, [item("a", 1), item("c", 1)])   // remote added c
        let merged = SyncSection.hotkeys.mergedPayload(base: base, local: local, remote: remote, localNewer: true)
        expect(merged["hotkeysEnabled"] == .bool(false), "scalar comes from the newer (local) side")
        expect(ids(jsonArray(at: ["hotkeyBindings", "__json_data__"], in: merged)) == ["a", "b", "c"],
               "items unioned across base/local/remote")
    }

    static func testSectionReplaceIsLWW() {
        let local: [String: JSONValue] = ["voiceEnabled": .bool(true)]
        let remote: [String: JSONValue] = ["voiceEnabled": .bool(false)]
        expect(SyncSection.voice.mergedPayload(base: [:], local: local, remote: remote, localNewer: true) == local,
               ".replace: localNewer returns local whole")
        expect(SyncSection.voice.mergedPayload(base: [:], local: local, remote: remote, localNewer: false) == remote,
               ".replace: !localNewer returns remote whole")
    }

    static func testSectionPersonasEnvelopePath() {
        func env(_ version: Int, _ items: [JSONValue]) -> [String: JSONValue] {
            ["envelope": .object(["version": .int(version), "personas": .array(items)])]
        }
        let base = env(1, [item("p1", 1)])
        let local = env(2, [item("p1", 1), item("p2", 1)])   // local added p2, bumped version
        let remote = env(1, [item("p1", 1), item("p3", 1)])  // remote added p3
        let merged = SyncSection.personas.mergedPayload(base: base, local: local, remote: remote, localNewer: true)
        expect(ids(jsonArray(at: ["envelope", "personas"], in: merged)) == ["p1", "p2", "p3"],
               "personas unioned at envelope.personas")
        if case let .object(e)? = merged["envelope"] { expect(e["version"] == .int(2), "envelope.version from newer side") }
        else { expect(false, "envelope object present") }
    }

    static func testSectionAbsentPathNotMaterialized() {
        // No side has hotkeyBindings — merge must not create an empty blob.
        let local: [String: JSONValue] = ["hotkeysEnabled": .bool(true)]
        let remote: [String: JSONValue] = ["hotkeysEnabled": .bool(true)]
        let merged = SyncSection.hotkeys.mergedPayload(base: [:], local: local, remote: remote, localNewer: true)
        expect(merged["hotkeyBindings"] == nil, "absent collection path is not materialized")
        expect(merged == local, "frame returned untouched when no side has the collection")
    }

    // MARK: - Engine flows

    static func newState() -> SyncStateStore {
        let d = UserDefaults(suiteName: "io.keymic.app.tests.mergestate.\(UUID().uuidString)")!
        return SyncStateStore(defaults: d, now: { Date(timeIntervalSince1970: 1_000_000) })
    }
    static func newEnv() -> SyncEnvironment {
        let d = UserDefaults(suiteName: "io.keymic.app.tests.mergeenv.\(UUID().uuidString)")!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return SyncEnvironment(defaults: d, personasFileURL: tmp)
    }
    static func writeBlob(_ env: SyncEnvironment, key: String, _ items: [JSONValue]) {
        env.defaults.set(JSONValue.object(["__json_data__": .array(items)]).foundationValue, forKey: key)
    }
    static func blobIds(_ env: SyncEnvironment, key: String) -> [String] {
        guard let raw = env.defaults.object(forKey: key), let jv = JSONValue.from(foundation: raw),
              case let .object(o) = jv else { return [] }
        return ids(jsonArray(at: ["__json_data__"], in: o))
    }
    static func blobPayload(_ key: String, _ items: [JSONValue]) -> [String: JSONValue] {
        [key: .object(["__json_data__": .array(items)])]
    }

    // Download: local add + remote add ⇒ local becomes union; base recorded = remote; no PUT.
    static func testDownloadMergesAndRecordsRemoteBase() async {
        let env = newEnv(); let state = newState()
        writeBlob(env, key: "hotkeyBindings", [item("a", 1), item("local", 1)])
        state.recordSynced(.hotkeys, remoteData: blobPayload("hotkeyBindings", [item("a", 1)]),
                           revision: 1, modifiedAt: Date(timeIntervalSince1970: 900_000))
        let t = MergeFakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "hotkeys": RemoteSection(payload: blobPayload("hotkeyBindings", [item("a", 1), item("remote", 1)]),
                                     modifiedAt: Date(timeIntervalSince1970: 950_000), revision: 2, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let changed = try! await engine.download(applying: [.hotkeys], token: "tok")
        expect(changed.contains(.hotkeys), "hotkeys changed by merge")
        expect(blobIds(env, key: "hotkeyBindings") == ["a", "local", "remote"], "local becomes the union")
        expect(state.state(for: .hotkeys).lastRemoteData == blobPayload("hotkeyBindings", [item("a", 1), item("remote", 1)]),
               "base recorded = remote (cloud value), not merged local")
        expect(t.putBodies.isEmpty, "download performs no PUT")
    }

    // After a pull that leaves local-only items, bookkeeping must read localNewer.
    static func testDownloadStatusBecomesLocalNewer() async {
        let env = newEnv(); let state = newState()
        writeBlob(env, key: "hotkeyBindings", [item("a", 1), item("local", 1)])
        let remoteMod = Date(timeIntervalSince1970: 950_000)
        state.recordSynced(.hotkeys, remoteData: blobPayload("hotkeyBindings", [item("a", 1)]),
                           revision: 1, modifiedAt: Date(timeIntervalSince1970: 900_000))
        let t = MergeFakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "hotkeys": RemoteSection(payload: blobPayload("hotkeyBindings", [item("a", 1)]),
                                     modifiedAt: remoteMod, revision: 2, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        _ = try! await engine.download(applying: [.hotkeys], token: "tok")
        expect(state.state(for: .hotkeys).localModifiedAt! > remoteMod,
               "localModifiedAt stamped past cloud time ⇒ refreshStatus reports .localNewer")
    }

    // Upload: PUT carries the merged union; on accept, base = merged, local = merged.
    static func testUploadPutsMergedAndConverges() async {
        let env = newEnv(); let state = newState()
        writeBlob(env, key: "hotkeyBindings", [item("a", 1), item("local", 1)])
        state.recordSynced(.hotkeys, remoteData: blobPayload("hotkeyBindings", [item("a", 1)]),
                           revision: 1, modifiedAt: Date(timeIntervalSince1970: 1_500_000)) // local newer
        let t = MergeFakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "hotkeys": RemoteSection(payload: blobPayload("hotkeyBindings", [item("a", 1), item("remote", 1)]),
                                     modifiedAt: Date(timeIntervalSince1970: 950_000), revision: 2, deviceId: "other"),
        ])
        t.putResponses = [ConfigPutResponse(accepted: ["hotkeys"], stale: [:])]
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        _ = try! await engine.upload(sections: [.hotkeys], token: "tok")
        let put = ids(jsonArray(at: ["hotkeyBindings", "__json_data__"], in: t.putBodies.first!.sections["hotkeys"]!.payload))
        expect(put == ["a", "local", "remote"], "PUT carries the merged union")
        expect(blobIds(env, key: "hotkeyBindings") == ["a", "local", "remote"], "local reflects merged union after accept")
        expect(state.state(for: .hotkeys).lastRemoteData == blobPayload("hotkeyBindings", [item("a", 1), item("local", 1), item("remote", 1)]),
               "base recorded = merged (cloud now holds merged)")
    }

    // keyMapping round-trip (a second collection section) via download.
    static func testUploadKeyMappingRoundTrip() async {
        let env = newEnv(); let state = newState()
        writeBlob(env, key: "keyMappingList", [item("m1", 1)])
        state.recordSynced(.keyMapping, remoteData: blobPayload("keyMappingList", [item("m1", 1)]),
                           revision: 1, modifiedAt: Date(timeIntervalSince1970: 900_000))
        let t = MergeFakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "keyMapping": RemoteSection(payload: blobPayload("keyMappingList", [item("m1", 1), item("m2", 1)]),
                                        modifiedAt: Date(timeIntervalSince1970: 950_000), revision: 2, deviceId: "other"),
        ])
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        let changed = try! await engine.download(applying: [.keyMapping], token: "tok")
        expect(changed.contains(.keyMapping), "keyMapping merged remote add in")
        expect(blobIds(env, key: "keyMappingList") == ["m1", "m2"], "keyMapping list unioned")
    }

    // Stale retry: a concurrent write is returned as stale; re-merge + re-PUT with a
    // strictly newer timestamp keeps the local add.
    static func testUploadStaleRetryDeliversLocalAdd() async {
        let env = newEnv(); let state = newState()
        writeBlob(env, key: "hotkeyBindings", [item("a", 1), item("local", 1)])
        state.recordSynced(.hotkeys, remoteData: blobPayload("hotkeyBindings", [item("a", 1)]),
                           revision: 1, modifiedAt: Date(timeIntervalSince1970: 1_500_000))
        let staleMod = Date(timeIntervalSince1970: 1_600_000)
        let t = MergeFakeTransport()
        t.getResponse = ConfigGetResponse(sections: [
            "hotkeys": RemoteSection(payload: blobPayload("hotkeyBindings", [item("a", 1)]),
                                     modifiedAt: Date(timeIntervalSince1970: 900_000), revision: 2, deviceId: "other"),
        ])
        t.putResponses = [
            ConfigPutResponse(accepted: [], stale: [
                "hotkeys": RemoteSection(payload: blobPayload("hotkeyBindings", [item("a", 1), item("conc", 1)]),
                                         modifiedAt: staleMod, revision: 3, deviceId: "other"),
            ]),
            ConfigPutResponse(accepted: ["hotkeys"], stale: [:]),
        ]
        let engine = SyncEngine(env: env, state: state, deviceId: "devA", transport: t)
        _ = try! await engine.upload(sections: [.hotkeys], token: "tok")
        expect(t.putBodies.count == 2, "one retry after stale")
        let second = t.putBodies[1].sections["hotkeys"]!
        expect(second.modifiedAt > staleMod, "retry PUT timestamp is strictly newer than the stale record")
        let secondIds = ids(jsonArray(at: ["hotkeyBindings", "__json_data__"], in: second.payload))
        expect(secondIds.contains("local") && secondIds.contains("conc"),
               "retry PUT re-merges the local add with the concurrent write")
    }
}
