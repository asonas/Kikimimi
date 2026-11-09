import Foundation
import Testing
@testable import RecorderCore

private let start = Date(timeIntervalSince1970: 1_794_234_600) // 2026-11-09 23:30 JST
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let app = AppInfo(version: "0.1", build: "1", os: "test")
private let mic = TrackSource.mic(deviceUID: "uid", deviceName: "Mic", channel: 1, deviceChannels: 2)

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func store(_ root: URL) -> SessionStore {
    SessionStore(root: root, now: { start }, timeZone: { tokyo })
}

private func create(_ store: SessionStore, company: String = "Acme") async throws -> (ref: SessionRef, lease: CaptureLease) {
    try await store.create(.init(company: company, remote: .allSystemAudio), mic: mic, remote: .allSystemAudio, app: app)
}

private func meta() -> SessionMeta {
    SessionMeta(id: UUID(), company: "Acme", title: nil, timeZone: tokyo.identifier, startedAt: start,
                app: app, tracks: .init(me: .init(source: mic), remote: .init(source: .allSystemAudio)))
}

private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func segments(version: Int = 1) -> SegmentsFile {
    SegmentsFile(schemaVersion: version, createdAt: start,
                 transcriber: .init(engine: "fake", engineVersion: nil, model: "test", language: "ja", chunking: "none"),
                 tracks: .init(remote: .transcribed), segments: [])
}

@Test func folderNamerSanitizesAndPreservesGraphemeClusters() {
    let family = "👨‍👩‍👧‍👦"
    let rows: [(String, String)] = [
        ("A/B:C", "A-B-C"), ("A\\B*?\"<>|C", "A-B------C"),
        ("..", "untitled"), (".hidden", "hidden"), ("--_...Acme..._--", "Acme"),
        ("  \t\n ", "untitled"), ("A   B", "A_B"), ("A\u{0000}B", "A-B"),
        ("Cafe\u{301}", "Café"),
        (String(repeating: "社", count: 41), String(repeating: "社", count: 40)),
        (String(repeating: "社", count: 39) + family + "後", String(repeating: "社", count: 39) + family),
    ]
    for (company, expected) in rows {
        let name = FolderNamer.name(company: company, startedAt: start, timeZone: tokyo, taken: [])
        #expect(name == "2026-11-09_2330_" + expected)
    }
    let utc = FolderNamer.name(company: "Acme", startedAt: start, timeZone: TimeZone(secondsFromGMT: 0)!, taken: [])
    #expect(utc == "2026-11-09_1430_Acme")
}

@Test func folderNamerResolvesCaseInsensitiveAndManyCollisions() {
    let base = "2026-11-09_2330_Acme"
    #expect(FolderNamer.name(company: "Acme", startedAt: start, timeZone: tokyo, taken: [base.lowercased()]) == base + "-2")
    var taken = Set((2...1000).map { base + "-\($0)" }); taken.insert(base)
    #expect(FolderNamer.name(company: "Acme", startedAt: start, timeZone: tokyo, taken: taken) == base + "-1001")
}

@Test func sessionClassifierExhaustiveEvidenceTable() {
    for finished in [false, true] {
        for held in [false, true] {
            for spoolMask in 0..<4 {
                for audioMask in 0..<4 {
                    for anchorMask in 0..<4 {
                        for validSegments in [false, true] {
                            var value = meta()
                            if finished { value.capture = .finished(endedAt: start, reason: .user) }
                            if anchorMask & 1 != 0 { value.tracks.me?.firstSampleHostSeconds = 100 }
                            if anchorMask & 2 != 0 { value.tracks.remote?.firstSampleHostSeconds = 101 }
                            let inventory = FolderInventory(meta: .success(value), lockHeld: held,
                                spoolExists: .init(me: spoolMask & 1 != 0, remote: spoolMask & 2 != 0),
                                finalAudioExists: .init(me: audioMask & 1 != 0, remote: audioMask & 2 != 0),
                                segmentsDecodes: validSegments)
                            let expected: SessionState
                            if held { expected = .capturing }
                            else if !finished || spoolMask != 0 || (anchorMask & ~audioMask) != 0 { expected = .needsFinalize }
                            else if audioMask == 0 { expected = .unusable("no audio") }
                            else { expected = validSegments ? .transcribed : .readyToTranscribe }
                            #expect(SessionClassifier.classify(inventory) == expected)
                        }
                    }
                }
            }
        }
    }
}

@Test func sessionClassifierRejectsBadMetaBeforeHeldLock() {
    for problem in [InventoryProblem.missing, .undecodable("bad"), .newerSchema(2)] {
        for held in [false, true] {
            let inventory = FolderInventory(meta: .failure(problem), lockHeld: held,
                spoolExists: .init(me: true), finalAudioExists: .init(me: true), segmentsDecodes: true)
            guard case .unusable = SessionClassifier.classify(inventory) else {
                Issue.record("invalid meta must take precedence over a lock"); continue
            }
        }
    }
}

@Test func sessionStoreCreatesTwentyConcurrentFoldersWithHeldLeases() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let shared = store(root)
    let results = try await withThrowingTaskGroup(of: (SessionRef, CaptureLease).self) { group in
        for _ in 0..<20 { group.addTask { try await create(shared) } }
        var results: [(SessionRef, CaptureLease)] = []
        for try await value in group { results.append(value) }
        return results
    }
    defer { results.forEach { $0.1.release() } }
    #expect(Set(results.map { $0.0.folder }).count == 20)
    #expect(Set(results.map { $0.0.id }).count == 20)
    for (ref, _) in results {
        #expect(CaptureLease.isHeld(ref.folder.lock))
        #expect(CaptureLease.acquire(ref.folder.lock) == nil)
        #expect(try await shared.state(of: ref) == .capturing)
        let value = try await shared.meta(of: ref)
        #expect(value.id == ref.id)
        #expect(value.startedAt == start)
        #expect(value.timeZone == "Asia/Tokyo")
        #expect(value.tracks.me?.source == mic)
        #expect(value.tracks.remote?.source == .allSystemAudio)
        #expect(value.capture == .inProgress)
    }
}

@Test func sessionStoreReservesNamesAcrossIndependentStores() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let results = try await withThrowingTaskGroup(of: (SessionRef, CaptureLease).self) { group in
        for _ in 0..<20 { group.addTask { try await create(store(root)) } }
        var results: [(SessionRef, CaptureLease)] = []
        for try await value in group { results.append(value) }
        return results
    }
    defer { results.forEach { $0.1.release() } }
    #expect(Set(results.map { $0.0.folder }).count == 20)
    #expect(results.allSatisfy { CaptureLease.isHeld($0.0.folder.lock) })
}

@Test func sessionStoreAtomicUpdatesNeverExposePartialMeta() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store); defer { lease.release() }
    try await store.update(ref) { $0.company = "initial"; $0.title = "initial" }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for _ in 0..<1000 {
                let value = try decoder.decode(SessionMeta.self, from: Data(contentsOf: ref.folder.meta))
                #expect(value.company == value.title)
                await Task.yield()
            }
        }
        group.addTask {
            for index in 0..<200 {
                let text = "\(index)" + String(repeating: "社", count: index % 2 == 0 ? 1 : 10000)
                try await store.update(ref) { $0.company = text; $0.title = text }
                await Task.yield()
            }
        }
        try await group.waitForAll()
    }
}

@Test func sessionStoreConcurrentUpdatesDoNotLoseChanges() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store); defer { lease.release() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<100 { group.addTask { try await store.update(ref) { $0.company += "x" } } }
        try await group.waitForAll()
    }
    #expect(try await store.meta(of: ref).company == "Acme" + String(repeating: "x", count: 100))
}

@Test func sessionStoreListsRenamedSessionsAndIgnoresGarbage() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store)
    lease.release()
    for name in ["unrelated", "broken"] {
        let folder = SessionFolder(url: root.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        if name == "broken" { try Data("bad".utf8).write(to: folder.meta) }
    }
    try Data().write(to: root.appendingPathComponent("plain-file"))
    let renamed = root.appendingPathComponent("renamed")
    try FileManager.default.moveItem(at: ref.folder.url, to: renamed)
    let list = try await store.list()
    #expect(list.count == 1)
    #expect(list.first?.id == ref.id)
    #expect(list.first?.ref.folder.url.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    #expect(list.first?.durationSeconds == nil)
    #expect(list.first?.state == .needsFinalize)
}

@Test func sessionStoreLockAndAudioEvidenceDetermineState() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store)
    #expect(try await store.state(of: ref) == .capturing)
    lease.release()
    #expect(try await store.state(of: ref) == .needsFinalize)
    try await store.update(ref) { $0.capture = .finished(endedAt: start, reason: .user) }
    #expect(try await store.state(of: ref) == .unusable("no audio"))
    try Data().write(to: ref.folder.audio(.remote))
    #expect(try await store.state(of: ref) == .readyToTranscribe)
    try write(segments(), to: ref.folder.segments)
    #expect(try await store.state(of: ref) == .transcribed)
    #expect(try await store.segments(of: ref) == segments())
    try write(segments(version: 2), to: ref.folder.segments)
    #expect(try await store.state(of: ref) == .readyToTranscribe)
    try Data("bad".utf8).write(to: ref.folder.segments)
    #expect(try await store.state(of: ref) == .readyToTranscribe)
    try Data().write(to: ref.folder.spool(.me))
    #expect(try await store.state(of: ref) == .needsFinalize)
    let secondLease = try #require(CaptureLease.acquire(ref.folder.lock))
    #expect(try await store.state(of: ref) == .capturing)
    secondLease.release()
}

@Test func sessionStoreRefusesNewerSchemaWithoutWritingOrDeleting() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store); defer { lease.release() }
    let future = Data(#"{"schemaVersion":2,"future":"preserve me"}"#.utf8)
    try future.write(to: ref.folder.meta)
    guard case .unusable = try await store.state(of: ref) else { Issue.record("expected unusable"); return }
    await #expect(throws: SessionMetaError.newerThanSupported(found: 2, supported: 1)) {
        try await store.update(ref) { $0.company = "changed" }
    }
    await #expect(throws: SessionMetaError.self) { try await store.discardIfEmpty(ref) }
    #expect(try Data(contentsOf: ref.folder.meta) == future)
}

@Test func sessionStoreDiscardRefusesEveryAudioArtifact() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    for track in Track.allCases {
        for kind in 0..<3 {
            let (ref, lease) = try await create(store); defer { lease.release() }
            let file = [ref.folder.spool(track), ref.folder.audio(track), ref.folder.audioPart(track)][kind]
            let bytes = Data([1, 2, 3]); try bytes.write(to: file)
            await #expect(throws: CocoaError.self) { try await store.discardIfEmpty(ref) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
    let (empty, lease) = try await create(store); defer { lease.release() }
    try await store.discardIfEmpty(empty)
    #expect(!FileManager.default.fileExists(atPath: empty.folder.url.path))
}

@Test func sessionStoreRejectsUpdateIntroducingNewerSchema() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store); defer { lease.release() }
    let before = try Data(contentsOf: ref.folder.meta)
    await #expect(throws: SessionMetaError.newerThanSupported(found: 2, supported: 1)) {
        try await store.update(ref) { $0.schemaVersion = 2 }
    }
    #expect(try Data(contentsOf: ref.folder.meta) == before)
}

@Test func sessionStoreHandlesMissingRootMetaAndSegments() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let missing = store(root.appendingPathComponent("absent"))
    #expect(try await missing.list().isEmpty)
    let ref = SessionRef(id: UUID(), folder: .init(url: root.appendingPathComponent("not-a-session")))
    #expect(try await missing.segments(of: ref) == nil)
    guard case .unusable = try await missing.state(of: ref) else { Issue.record("expected unusable"); return }
}

@Test func sessionStoreCreatePreservesExistingCaseInsensitiveCollision() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("2026-11-09_2330_acme")
    let bytes = Data("keep".utf8)
    try bytes.write(to: existing)
    let (ref, lease) = try await create(store(root)); defer { lease.release() }
    #expect(ref.folder.url.lastPathComponent == "2026-11-09_2330_Acme-2")
    #expect(try Data(contentsOf: existing) == bytes)
}

@Test func sessionTimelineOffsetsAndDurationIncludeLateStartingTrack() {
    var value = meta()
    #expect(SessionTimeline.offsets(of: value.tracks) == .init())
    #expect(SessionTimeline.duration(of: value) == 0)
    value.tracks.remote?.firstSampleHostSeconds = 100
    value.tracks.remote?.audio = .init(file: "remote", sampleRate: 48_000, frames: 96_000, peakDBFS: -1)
    #expect(SessionTimeline.offsets(of: value.tracks) == .init(remote: 0))
    #expect(SessionTimeline.duration(of: value) == 2)
    value.tracks.me?.firstSampleHostSeconds = 100.5
    value.tracks.me?.audio = .init(file: "self", sampleRate: 44_100, frames: 132_300, peakDBFS: -1)
    #expect(SessionTimeline.offsets(of: value.tracks) == .init(me: 0.5, remote: 0))
    #expect(SessionTimeline.duration(of: value) == 3.5)
    value.tracks.me?.firstSampleHostSeconds = 100
    #expect(SessionTimeline.offsets(of: value.tracks) == .init(me: 0, remote: 0))
}

@Test func sessionStoreListingDurationComesFromFinalizedAudio() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    let (ref, lease) = try await create(store); defer { lease.release() }
    try await store.update(ref) {
        $0.capture = .finished(endedAt: start.addingTimeInterval(9), reason: .user)
        $0.tracks.remote?.firstSampleHostSeconds = 100
        $0.tracks.remote?.audio = .init(file: "remote", sampleRate: 48_000, frames: 96_000, peakDBFS: -1)
        $0.tracks.me?.firstSampleHostSeconds = 100.5
        $0.tracks.me?.audio = .init(file: "self", sampleRate: 48_000, frames: 144_000, peakDBFS: -1)
    }
    #expect(try await store.list().first?.durationSeconds == 3.5)
}
