import Foundation

/// The versioned clipboard payload, independent of the project file version.
/// Stores offsets and musical annotations, never original UUIDs, inferred rests,
/// source files, tuning, analyses or an invented phrase/note duration.
public struct TabFragment: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pasteboardType = "app.roughscore.tab-fragment+json"
    public static let maximumEvents = 4096
    public static let maximumEncodedBytes = 1_048_576
    public static let maximumMemoUTF8Bytes = 16_384

    public struct Entry: Codable, Equatable, Sendable {
        public let relativeTime: Double
        public let lane: GuitarLane
        public let string: Int
        public let fret: Int?
        public let length: NoteLength?
        public let tentative: Bool
        public let memo: String

        public init(relativeTime: Double, lane: GuitarLane, string: Int,
                    fret: Int? = nil, length: NoteLength? = nil,
                    tentative: Bool = false, memo: String = "") {
            self.relativeTime = relativeTime; self.lane = lane; self.string = string
            self.fret = fret; self.length = length; self.tentative = tentative; self.memo = memo
        }
    }

    public let schemaVersion: Int
    public let events: [Entry]
    /// Preserves which copied note was primary without copying its UUID.
    public let primaryIndex: Int?

    public init(events: [Entry], primaryIndex: Int? = nil,
                schemaVersion: Int = Self.currentVersion) throws {
        self.schemaVersion = schemaVersion
        self.events = events
        self.primaryIndex = primaryIndex ?? (events.isEmpty ? nil : 0)
        try validate()
    }

    public static func copy(from project: ScoreProject, selection: TabSelection) throws -> Self {
        let selected = try selection.resolved(in: project)
        guard selected.count <= maximumEvents else { throw TabEditError.clipboardTooLarge }
        let origin = selection.rangeOrigin ?? selected.map(\.time).min() ?? 0
        guard origin.isFinite, origin >= 0, selected.allSatisfy({ $0.time >= origin }) else {
            // If selected notes moved before a remembered range start, reselect
            // explicitly; silently changing the anchor would lose leading silence.
            throw TabEditError.invalidCopyOrigin
        }
        let entries = selected.map {
            Entry(relativeTime: $0.time - origin, lane: $0.lane, string: $0.string,
                  fret: $0.fret, length: $0.length, tentative: $0.tentative, memo: $0.memo)
        }
        return try Self(events: entries, primaryIndex: selected.firstIndex { $0.id == selection.primaryID })
    }

    /// Use this entry point for untrusted pasteboard data: byte limit precedes parsing.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw TabEditError.clipboardTooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw TabEditError.clipboardTooLarge }
        return data
    }

    /// All typed construction and Codable decoding validate, so a decoded fragment
    /// cannot defer malformed data until a partially applied paste.
    public func validate() throws {
        guard schemaVersion == Self.currentVersion else { throw TabEditError.unsupportedFragmentVersion(schemaVersion) }
        guard events.count <= Self.maximumEvents else { throw TabEditError.clipboardTooLarge }
        if events.isEmpty {
            guard primaryIndex == nil else { throw TabEditError.invalidFragment }
        } else {
            guard let primaryIndex, events.indices.contains(primaryIndex) else { throw TabEditError.invalidFragment }
        }
        var memoBytes = 0
        for entry in events {
            guard entry.relativeTime.isFinite, entry.relativeTime >= 0, entry.relativeTime < 86_400,
                  (1...6).contains(entry.string), entry.fret.map({ (0...24).contains($0) }) ?? true else {
                throw TabEditError.invalidFragment
            }
            let size = entry.memo.utf8.count
            guard size <= Self.maximumMemoUTF8Bytes else { throw TabEditError.clipboardTooLarge }
            memoBytes += size
            guard memoBytes <= Self.maximumEncodedBytes else { throw TabEditError.clipboardTooLarge }
        }
        // Typed fragments obey the same full serialized byte limit as pasteboard
        // data, including JSON overhead/escaping. The memo budget bounds encoding.
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
            throw TabEditError.clipboardTooLarge
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, events, primaryIndex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentVersion else { throw TabEditError.unsupportedFragmentVersion(version) }
        var array = try container.nestedUnkeyedContainer(forKey: .events)
        var entries = [Entry]()
        while !array.isAtEnd {
            guard entries.count < Self.maximumEvents else { throw TabEditError.clipboardTooLarge }
            entries.append(try array.decode(Entry.self))
        }
        // Missing/null primary is accepted only for an empty fragment on the wire.
        let primary = try container.decodeIfPresent(Int.self, forKey: .primaryIndex)
        if !entries.isEmpty, primary == nil { throw TabEditError.invalidFragment }
        try self.init(events: entries, primaryIndex: primary, schemaVersion: version)
    }
}
