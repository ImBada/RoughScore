import Foundation

public enum GuitarLane: String, CaseIterable, Codable, Sendable, Identifiable {
    case left, right
    public var id: String { rawValue }
    public var title: String { self == .left ? "Guitar L" : "Guitar R" }
}

public enum ListeningSource: String, CaseIterable, Sendable, Identifiable {
    case stereo, left, right
    public var id: String { rawValue }
    public var title: String {
        switch self { case .stereo: "원곡 · Stereo"; case .left: "왼쪽 · L"; case .right: "오른쪽 · R" }
    }
}

public enum NoteLength: String, CaseIterable, Codable, Sendable, Identifiable {
    case whole, half, quarter, eighth, sixteenth
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .whole: "𝅝"; case .half: "𝅗𝅥"; case .quarter: "♩"; case .eighth: "♪"; case .sixteenth: "𝅘𝅥𝅯" }
    }
    public var title: String {
        switch self { case .whole: "온음표"; case .half: "2분음표"; case .quarter: "4분음표"; case .eighth: "8분음표"; case .sixteenth: "16분음표" }
    }
}

/// A sparse annotation. No event means untranscribed audio, never an inferred rest.
public struct TabEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var time: Double
    public var lane: GuitarLane
    public var string: Int // 1 = high E, 6 = low E
    public var fret: Int? // nil = heard here, pitch unknown
    public var length: NoteLength? // nil = rhythm deliberately unspecified
    public var tentative: Bool
    public var memo: String

    public init(id: UUID = UUID(), time: Double, lane: GuitarLane, string: Int,
                fret: Int? = nil, length: NoteLength? = nil, tentative: Bool = false, memo: String = "") {
        self.id = id; self.time = time; self.lane = lane; self.string = string
        self.fret = fret; self.length = length; self.tentative = tentative; self.memo = memo
    }
}

public struct AnalysisSummary: Codable, Equatable, Sendable {
    public var bpm: Double?
    public var key: String?
    public var beats: [Double]
    public var bars: [Double]
    public var sections: [TimeSpan]
    public var otherInstrumentRanges: [TimeSpan]
    public var provenance: AnalysisProvenance?
    public init(bpm: Double? = nil, key: String? = nil, beats: [Double] = [], bars: [Double] = [],
                sections: [TimeSpan] = [], otherInstrumentRanges: [TimeSpan] = [], provenance: AnalysisProvenance? = nil) {
        self.bpm = bpm; self.key = key; self.beats = beats; self.bars = bars
        self.sections = sections; self.otherInstrumentRanges = otherInstrumentRanges; self.provenance = provenance
    }
}

public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct ScoreProject: Codable, Equatable, Sendable {
    public var version = 1
    public var title: String
    public var audioPath: String?
    public var duration: Double
    // Optional v1 extensions: old documents decode without fabricated identity or pitch octaves.
    public var assets: [AudioAsset]?
    public var tuningDefinition: TuningDefinition?
    public var tuning: [String] = ["E", "B", "G", "D", "A", "E"]
    public var events: [TabEvent]
    public var analyses: [String: AnalysisSummary]
    public init(title: String = "새 프로젝트", audioPath: String? = nil, duration: Double = 24,
                events: [TabEvent] = [], analyses: [String: AnalysisSummary] = [:]) {
        self.title = title; self.audioPath = audioPath; self.duration = duration
        self.events = events; self.analyses = analyses
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw ProjectError.unsupportedVersion }
        guard duration.isFinite, duration > 0, duration <= 86_400,
              tuning.count == 6, Set(events.map(\.id)).count == events.count else { throw ProjectError.invalidData }
        if let assets {
            guard Set(assets.map(\.id)).count == assets.count,
                  assets.filter({ $0.role == .original }).count == 1 else { throw ProjectError.invalidData }
            for asset in assets { _ = try asset.validated() }
            if let original = originalAsset, original.reference.kind == .external,
               original.reference.path != audioPath { throw ProjectError.invalidData }
        }
        _ = try tuningDefinition?.validated()
        for event in events {
            guard event.time.isFinite, event.time >= 0, event.time < duration,
                  (1...6).contains(event.string), event.fret.map({ (0...24).contains($0) }) ?? true
            else { throw ProjectError.invalidData }
        }
        for (channel, summary) in analyses {
            if let provenance = summary.provenance {
                _ = try provenance.validated()
                guard provenance.channel == channel,
                      assets?.contains(where: { $0.id == provenance.assetID && $0.identity == provenance.identity }) == true
                else { throw ProjectError.invalidData }
            }
            guard summary.bpm.map({ $0.isFinite && $0 > 0 }) ?? true,
                  (summary.beats + summary.bars).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= duration }),
                  (summary.sections + summary.otherInstrumentRanges).allSatisfy({
                      $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration
                  }) else { throw ProjectError.invalidData }
        }
        return self
    }


    public func soundingMIDI(string: Int, fret: Int) -> Int? {
        guard (1...6).contains(string), (0...24).contains(fret) else { return nil }
        let definition = tuningDefinition ?? (tuning == ["E", "B", "G", "D", "A", "E"] ? TuningDefinition() : nil)
        guard let definition, (try? definition.validated()) != nil else { return nil }
        let value = definition.openMIDIPitches[string - 1] + definition.capo + fret
        return value <= 127 ? value : nil
    }

    public var originalAsset: AudioAsset? { assets?.first { $0.role == .original } }

    /// Relink never changes manual annotations. Only proven matching derived data may survive.
    public func relinkingOriginal(path: String, identity: AudioContentIdentity?, duration: Double) throws -> Self {
        var candidate = self
        let previous = originalAsset
        let original = AudioAsset(id: previous?.id ?? UUID(), reference: AudioReference(path: path), identity: identity)
        let sameContent = identity != nil && previous?.identity == identity
        candidate.analyses = sameContent ? analyses.filter { channel, summary in
            guard let p = summary.provenance else { return false }
            return p.assetID == original.id && p.identity == identity && p.channel == channel &&
                (summary.beats + summary.bars).allSatisfy { $0 <= duration } &&
                (summary.sections + summary.otherInstrumentRanges).allSatisfy { $0.end <= duration }
        } : [:]
        // Imported files are independently owned. Future derived/model assets must also carry proven provenance.
        candidate.assets = [original] + (assets ?? []).filter { $0.role != .original }
        candidate.duration = duration; candidate.audioPath = path
        return try candidate.validated()
    }

    public static var demo: Self {
        Self(title: "Late night sketch", duration: 24, events: [
            TabEvent(time: 2.0, lane: .left, string: 6, fret: 0),
            TabEvent(time: 2.5, lane: .left, string: 5, fret: 2),
            TabEvent(time: 3.0, lane: .left, string: 4, fret: 2),
            TabEvent(time: 3.5, lane: .left, string: 3, fret: 0, tentative: true),
            TabEvent(time: 5.0, lane: .left, string: 5, memo: "베이스와 겹침 · 다시 듣기"),
            TabEvent(time: 4.0, lane: .right, string: 2, fret: 8, length: .eighth),
            TabEvent(time: 4.5, lane: .right, string: 1, fret: 7, length: .eighth),
            TabEvent(time: 5.0, lane: .right, string: 1, fret: 10, tentative: true)
        ])
    }

    public static var longDemo: Self {
        var events: [TabEvent] = []
        // Sparse, authored phrases distributed across three minutes. No fabricated analysis.
        for start in stride(from: 2.0, to: 178.0, by: 16) {
            for event in demo.events {
                var copy = event
                copy.id = UUID(); copy.time = start + event.time - 2
                events.append(copy)
            }
        }
        return Self(title: "3분 스케치 · 합성 수동 예시", duration: 180, events: events)
    }
}

public enum ProjectError: LocalizedError {
    case unsupportedVersion, invalidData
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "지원하지 않는 프로젝트 버전입니다."
        case .invalidData: "시간, 줄, 프렛 또는 분석 데이터가 올바르지 않습니다."
        }
    }
}

public enum TabMath {
    public static func snap(_ time: Double, beats: [Double], enabled: Bool) -> Double {
        guard enabled, let nearest = beats.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= 0.12 else { return time }
        return nearest
    }
    public static func midi(string: Int, fret: Int) -> Int? {
        guard (1...6).contains(string), (0...24).contains(fret) else { return nil }
        return [64, 59, 55, 50, 45, 40][string - 1] + fret
    }
}
