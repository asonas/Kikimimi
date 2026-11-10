import Foundation
import Testing
@testable import RecorderCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func sessionGoldenFixturesRoundTrip() throws {
    for name in ["session-in-progress", "session-finished"] {
        let data = try fixture(name)
        let meta = try decoder().decode(SessionMeta.self, from: data)
        #expect(meta.event == nil)
        let encoded = try encoder().encode(meta)
        // Compare JSON values to pin the wire shape, independently of whitespace and key order.
        #expect(NSDictionary(dictionary: try object(encoded)) == NSDictionary(dictionary: try object(data)))
        #expect(try decoder().decode(SessionMeta.self, from: encoded) == meta)
    }
}

@Test func sessionEventSnapshotRoundTripsWithoutChangingSchema() throws {
    var meta = try decoder().decode(SessionMeta.self, from: fixture("session-in-progress"))
    for meetingURL in [nil, URL(string: "https://meet.google.com/abc")] {
        meta.event = SessionEvent(title: "会社A 面接", start: meta.startedAt, end: meta.startedAt.addingTimeInterval(3600),
                                  meetingURL: meetingURL, calendarTitle: "仕事")
        let data = try encoder().encode(meta)
        #expect(meta.schemaVersion == 1)
        #expect(try decoder().decode(SessionMeta.self, from: data) == meta)
        let event = try #require(try object(data)["event"] as? [String: Any])
        #expect(event["title"] as? String == "会社A 面接")
        #expect(event["calendarTitle"] as? String == "仕事")
        if meetingURL == nil { #expect(event["meetingURL"] == nil) }
    }
    meta.event = nil
    #expect(try object(encoder().encode(meta))["event"] == nil)
}

@Test func sessionRejectsEitherHalfFinishedCapture() throws {
    for missing in ["endedAt", "endReason"] {
        var json = try object(fixture("session-finished"))
        json.removeValue(forKey: missing)
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try decoder().decode(SessionMeta.self, from: data) }
    }
}

@Test func sessionRejectsNewerSchemaBeforeReadingItsFields() throws {
    // A future schema need not have any of v1's other fields.
    let data = Data(#"{"schemaVersion":2}"#.utf8)
    #expect(throws: SessionMetaError.newerThanSupported(found: 2, supported: 1)) {
        try decoder().decode(SessionMeta.self, from: data)
    }
}

@Test func sessionIgnoresUnknownKeysAtEveryLevel() throws {
    let original = try fixture("session-finished")
    var json = try object(original)
    json["future"] = ["value": true]
    var app = try #require(json["app"] as? [String: Any])
    app["future"] = 1
    json["app"] = app
    var tracks = try #require(json["tracks"] as? [String: Any])
    tracks["futureTrack"] = ["future": true]
    var me = try #require(tracks["self"] as? [String: Any])
    for key in ["source", "audio", "diagnostics", "failure"] {
        var nested = try #require(me[key] as? [String: Any])
        nested["future"] = true
        me[key] = nested
    }
    me["future"] = true
    tracks["self"] = me
    json["tracks"] = tracks
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(try decoder().decode(SessionMeta.self, from: data) == decoder().decode(SessionMeta.self, from: original))
}

@Test func sessionLocalDateUsesPersistedTimeZoneAcrossMidnight() throws {
    var json = try object(fixture("session-in-progress"))
    for (instant, tokyoDay, utcDay) in [
        ("2026-11-09T14:30:00Z", 9, 9), // 23:30 JST
        ("2026-11-09T15:30:00Z", 10, 9), // 00:30 JST
        ("2026-11-09T23:30:00Z", 10, 9), // 23:30 UTC
    ] {
        for (zone, expectedDay) in [("Asia/Tokyo", tokyoDay), ("UTC", utcDay)] {
            json["startedAt"] = instant
            json["timeZone"] = zone
            let data = try JSONSerialization.data(withJSONObject: json)
            let meta = try decoder().decode(SessionMeta.self, from: data)
            let restored = try decoder().decode(SessionMeta.self, from: encoder().encode(meta))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: restored.timeZone))
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: restored.startedAt)
            #expect(components.year == 2026)
            #expect(components.month == 11)
            #expect(components.day == expectedDay)
            if instant == "2026-11-09T14:30:00Z", zone == "Asia/Tokyo" {
                #expect(components.hour == 23)
                #expect(components.minute == 30)
            }
        }
    }
}

@Test func trackWireValuesAndSparsePerTrackRoundTrip() throws {
    #expect(Track.allCases.map(\.rawValue) == ["self", "remote"])
    for value in [PerTrack<Int>(), .init(me: 1), .init(remote: 2), .init(me: 1, remote: 2)] {
        let data = try encoder().encode(value)
        let json = try object(data)
        #expect(json.count == value.present.count)
        #expect(json["me"] == nil)
        #expect(json["self"] as? Int == value.me)
        #expect(json["remote"] as? Int == value.remote)
        #expect(try decoder().decode(PerTrack<Int>.self, from: data) == value)
        #expect(value.present.map(\.0) == Track.allCases.filter { value[$0] != nil })
    }
    var value = PerTrack<Int>()
    value[.remote] = 2
    value[.me] = 1
    value[.remote] = nil
    #expect(value == .init(me: 1))
}

@Test func trackSourceDiscriminatorsAndOptionalChannelRoundTrip() throws {
    let cases: [(TrackSource, String)] = [
        (.mic(deviceUID: "uid", deviceName: "Mic", channel: nil, deviceChannels: 2), "mic"),
        (.mic(deviceUID: "uid", deviceName: "Mic", channel: 1, deviceChannels: 2), "mic"),
        (.app(bundleID: "com.example.call", name: "Call"), "app"),
        (.allSystemAudio, "allSystemAudio"),
    ]
    for (source, kind) in cases {
        let data = try encoder().encode(source)
        #expect(try object(data)["kind"] as? String == kind)
        #expect(try decoder().decode(TrackSource.self, from: data) == source)
    }
    let unknown = Data(#"{"kind":"future"}"#.utf8)
    #expect(throws: DecodingError.self) { try decoder().decode(TrackSource.self, from: unknown) }
}

@Test func sessionCaptureEndReasonsRoundTrip() throws {
    var meta = try decoder().decode(SessionMeta.self, from: fixture("session-in-progress"))
    #expect(meta.capture == .inProgress)
    for reason in [EndReason.user, .quit, .captureLost, .recovered] {
        meta.capture = .finished(endedAt: meta.startedAt.addingTimeInterval(60), reason: reason)
        #expect(try decoder().decode(SessionMeta.self, from: encoder().encode(meta)) == meta)
    }
}

@Test func trackAudioDurationAndSilenceThreshold() {
    var audio = TrackAudio(file: "audio-self.m4a", sampleRate: 48_000, frames: 96_000, peakDBFS: -70)
    #expect(audio.durationSeconds == 2)
    #expect(audio.isEffectivelySilent)
    audio.peakDBFS = -70.001
    #expect(audio.isEffectivelySilent)
    audio.peakDBFS = -69.999
    #expect(!audio.isEffectivelySilent)
}

@Test func sessionFolderOwnsArtifactPathsAndIdentitySurvivesRename() {
    let folder = SessionFolder(url: URL(fileURLWithPath: "/tmp/session"))
    #expect(folder.meta.lastPathComponent == "meta.json")
    #expect(folder.segments.lastPathComponent == "segments.json")
    #expect(folder.transcript.lastPathComponent == "transcript.md")
    #expect(folder.transcriptBackup.lastPathComponent == "transcript.prev.md")
    #expect(folder.lock.lastPathComponent == "capture.lock")
    for track in Track.allCases {
        #expect(folder.spool(track).lastPathComponent == "audio-\(track.rawValue).spool.caf")
        #expect(folder.audio(track).lastPathComponent == "audio-\(track.rawValue).m4a")
        #expect(folder.audioPart(track).lastPathComponent == "audio-\(track.rawValue).m4a.part")
    }
    let ref = SessionRef(id: UUID(), folder: folder)
    let renamed = SessionRef(id: ref.id, folder: .init(url: URL(fileURLWithPath: "/tmp/renamed")))
    #expect(ref.id == renamed.id)
}
