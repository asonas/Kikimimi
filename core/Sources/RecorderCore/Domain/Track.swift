import Foundation

/// The two capture sources, and (in Phase 1) the speaker label too.
/// Raw values are the JSON keys/values in meta.json and segments.json.
///
/// Phase 3 diarization will split `remote` into several speakers. That will add an optional
/// `speakerIndex` next to `speaker` in segments.json; `Track` itself stays two-valued.
public enum Track: String, Codable, Sendable, CaseIterable, Hashable {
    case me = "self"
    case remote

    /// Order used to break ties between segments with equal start times:
    /// the remote side first (a question precedes the answer that starts "at the same time").
    var mergeRank: Int { self == .remote ? 0 : 1 }
}

/// A *sparse* per-track value, for persisted data where a track may legitimately be absent
/// (no audio ever arrived, track skipped). JSON shape: {"self": ..., "remote": ...} with absent keys omitted.
public struct PerTrack<Value: Sendable>: Sendable {
    public var me: Value?
    public var remote: Value?
    public init(me: Value? = nil, remote: Value? = nil) { self.me = me; self.remote = remote }

    public subscript(track: Track) -> Value? {
        get { track == .me ? me : remote }
        set { if track == .me { me = newValue } else { remote = newValue } }
    }
    /// Present tracks in `Track.allCases` order.
    public var present: [(Track, Value)] { Track.allCases.compactMap { t in self[t].map { (t, $0) } } }
}

extension PerTrack: Equatable where Value: Equatable {}

extension PerTrack: Codable where Value: Codable {
    private enum Keys: String, CodingKey { case me = "self", remote }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        me = try c.decodeIfPresent(Value.self, forKey: .me)
        remote = try c.decodeIfPresent(Value.self, forKey: .remote)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(me, forKey: .me)
        try c.encodeIfPresent(remote, forKey: .remote)
    }
}

/// A *total* per-track value for in-memory state that always has both slots (health, levels).
public struct TrackPair<Value: Sendable>: Sendable {
    public var me: Value
    public var remote: Value
    public init(me: Value, remote: Value) { self.me = me; self.remote = remote }
    public init(both value: Value) { self.init(me: value, remote: value) }
    public subscript(track: Track) -> Value {
        get { track == .me ? me : remote }
        set { if track == .me { me = newValue } else { remote = newValue } }
    }
}
extension TrackPair: Equatable where Value: Equatable {}
